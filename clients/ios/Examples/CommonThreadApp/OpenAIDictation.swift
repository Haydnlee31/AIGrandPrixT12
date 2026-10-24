import Foundation

/// The provider credential stays on the relay. Recordings are sent only after Stop.
enum OpenAIDictation {
    static let maximumBytes = 4 * 1_024 * 1_024
    enum Failure: LocalizedError, Equatable {
        case configuration, noSpeech, tooLarge, unavailable, network, busy
        var errorDescription: String? {
            switch self {
            case .configuration: "Connect AI in Profile to use OpenAI dictation."
            case .noSpeech: "No clear speech was found. Record another note or type it."
            case .tooLarge: "That voice note is too long. Keep it under one minute."
            case .unavailable: "Couldn’t transcribe this recording. Try again or type your note."
            case .network: "Couldn’t reach OpenAI dictation. Check your connection and retry."
            case .busy: "Dictation is busy. Your recording is ready to retry."
            }
        }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func transcribe(_ bytes: Data) async throws -> String {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.tooLarge }
        guard let connection = try CaptureIntelligence.configuration() else { throw Failure.configuration }
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/dictation"))
        request.httpMethod = "POST"; request.timeoutInterval = 40
        request.setValue("Bearer " + connection.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["audio_data_url": "data:audio/mp4;base64," + bytes.base64EncodedString()])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40; configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, data.count <= 32_768 else { throw Failure.unavailable }
            switch response.statusCode {
            case 200:
                struct Transcript: Decodable { let text: String }
                guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Failure.unavailable }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw Failure.noSpeech }
                guard text.count <= 8_000 else { throw Failure.unavailable }
                return text
            case 401, 403: throw Failure.configuration
            case 413: throw Failure.tooLarge
            case 422:
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let error = value?["error"] as? [String: Any]
                throw error?["code"] as? String == "no_speech" ? Failure.noSpeech : Failure.unavailable
            case 429: throw Failure.busy
            default: throw Failure.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw Failure.network }
    }
}

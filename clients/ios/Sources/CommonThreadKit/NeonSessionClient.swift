import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A managed Neon session. Persist only in Keychain; never UserDefaults or logs.
public struct LoginCredential: Codable, Sendable {
    public let subject: String
    public let email: String
    public var cookie: String
}
public enum LoginError: Error, LocalizedError {
    case expired, changedAccount, unavailable, message(String)
    public var errorDescription: String? {
        switch self {
        case .expired: return "Sign in again in Profile to continue syncing. Your pending saves are safe."
        case .changedAccount: return "The signed-in account changed. Please reconnect before syncing."
        case .unavailable: return "Sign-in is temporarily unavailable. Please try again."
        case .message(let value): return value
        }
    }
}
private final class LoginNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Calls the shared backend's narrow transport to Neon's managed email-code API.
/// Explicit cookies keep sessions out of URLSession's global cookie jar.
public actor NeonSessionClient {
    private let baseURL: URL
    private let session: URLSession
    private static let cookieName = "__Secure-neon-auth.session_token"
    public init(baseURL: URL, session: URLSession? = nil) throws {
        _ = try CommonThreadClient(baseURL: baseURL) { "" }
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: config, delegate: LoginNoRedirects(), delegateQueue: nil)
    }
    private func request(_ operation: String, body: [String:String]? = nil, cookie: String? = nil) async throws -> (Data, String?) {
        let url = baseURL.appendingPathComponent("v1/auth/session/" + operation)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("1", forHTTPHeaderField: "X-Mynah-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse, response.url?.host == baseURL.host else { throw LoginError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw LoginError.expired }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String:Any])?["message"] as? String
            throw LoginError.message(message ?? "Could not sign in. Please try again.")
        }
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
        }
        let updated = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first { $0.name == Self.cookieName }
        return (data, updated?.value)
    }
    public func sendCode(email: String) async throws {
        _ = try await request("email-otp/send-verification-otp", body: ["email":email, "type":"sign-in"])
    }
    public func signIn(email: String, code: String) async throws -> LoginCredential {
        let (data, cookie) = try await request("sign-in/email-otp", body:["email":email,"otp":code])
        struct User: Decodable { let id: String; let email: String; let emailVerified: Bool }
        struct Result: Decodable { let user: User }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard let cookie, !cookie.isEmpty, result.user.emailVerified else { throw LoginError.expired }
        return LoginCredential(subject: result.user.id, email: result.user.email, cookie: cookie)
    }
    public func token(for credential: LoginCredential) async throws -> (token: String, credential: LoginCredential, expires: Date) {
        var credential = credential
        let (sessionData, refreshed) = try await request("get-session", cookie: credential.cookie)
        let value = try JSONSerialization.jsonObject(with: sessionData)
        guard let user = (value as? [String:Any])?["user"] as? [String:Any] else { throw LoginError.expired }
        guard user["id"] as? String == credential.subject else { throw LoginError.changedAccount }
        if let refreshed { credential.cookie = refreshed }
        let (data, updated) = try await request("token", cookie: credential.cookie)
        struct Result: Decodable { let token: String }
        let token = try JSONDecoder().decode(Result.self, from: data).token
        // A client-side account guard, not authentication: the API separately
        // verifies the signature, issuer, audience, verified email and expiry.
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw LoginError.expired }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try JSONSerialization.jsonObject(with: decoded) as? [String:Any],
              claims["sub"] as? String == credential.subject,
              let expires = claims["exp"] as? Double, expires > Date().timeIntervalSince1970 + 30 else { throw LoginError.changedAccount }
        if let updated { credential.cookie = updated }
        return (token, credential, Date(timeIntervalSince1970: expires))
    }
    public func signOut(_ credential: LoginCredential) async throws {
        _ = try await request("sign-out", body:[:], cookie:credential.cookie)
    }
}

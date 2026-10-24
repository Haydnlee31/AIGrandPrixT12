import XCTest
import Foundation
@testable import CommonThreadKit

final class LoginTests: XCTestCase {
    private let origin = URL(string: "https://mynah.example")!
    private func client() throws -> NeonSessionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return try NeonSessionClient(baseURL: origin, session: URLSession(configuration: config))
    }
    private func jwt(_ subject: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject:["sub":subject,"exp":Date().timeIntervalSince1970 + 900])
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }
    func testVerifiedLoginKeepsSessionCookieForSecureStorage() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/session/sign-in/email-otp")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Mynah-Auth"), "1")
            return (200, Data(#"{"user":{"id":"alice","email":"alice@example.com","emailVerified":true}}"#.utf8), ["Set-Cookie":"__Secure-neon-auth.session_token=secret-session; Path=/v1/auth/session; HttpOnly; Secure; SameSite=Lax; Max-Age=604800"])
        }
        let result = try await client().signIn(email:"alice@example.com", code:"123456")
        XCTAssertEqual(result.subject, "alice")
        XCTAssertEqual(result.cookie, "secret-session")
        XCTAssertEqual(try JSONDecoder().decode(LoginCredential.self, from: JSONEncoder().encode(result)).subject, "alice")
    }
    func testTokenRefreshIsAccountBoundAndPreservesRotatedCookie() async throws {
        let token = try jwt("alice")
        MockURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "get-session" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-neon-auth.session_token=before")
                return (200, Data(#"{"user":{"id":"alice"}}"#.utf8), ["Set-Cookie":"__Secure-neon-auth.session_token=after; Path=/; Secure; HttpOnly"])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-neon-auth.session_token=after")
            return (200, try JSONSerialization.data(withJSONObject:["token":token]), [:])
        }
        let result = try await client().token(for: LoginCredential(subject:"alice",email:"alice@example.com",cookie:"before"))
        XCTAssertEqual(result.token, token); XCTAssertEqual(result.credential.cookie, "after")
    }
    func testAccountSwitchDuringRefreshDoesNotReturnAnotherUsersToken() async throws {
        let token = try jwt("bob")
        MockURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "get-session" { return (200, Data(#"{"user":{"id":"alice"}}"#.utf8), [:]) }
            return (200, try JSONSerialization.data(withJSONObject:["token":token]), [:])
        }
        do { _ = try await client().token(for: LoginCredential(subject:"alice",email:"alice@example.com",cookie:"before")); XCTFail("Expected account guard") }
        catch LoginError.changedAccount {}
    }
}

import Foundation

struct CloudUser: Codable, Equatable { var id: UUID; var email: String }

struct StoredSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: CloudUser
}

/// Email one-time-code sign-in (no passwords anywhere). The session lives in the Keychain and refreshes
/// itself; if the refresh token is rejected the app quietly signs out.
@MainActor
final class CloudSession: ObservableObject {
    static let shared = CloudSession()
    private static let account = "session"

    @Published private(set) var session: StoredSession?
    private var refreshTask: Task<StoredSession, Error>?

    var isSignedIn: Bool { session != nil }
    var email: String? { session?.user.email }

    private init() {
        if let data = Keychain.load(account: Self.account), let s = try? JSONDecoder().decode(StoredSession.self, from: data) {
            session = s
        }
    }

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: UUID; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }

    /// Sends a 6-digit code. `create_user` makes first-time sign-in and sign-up the same flow.
    func sendCode(to email: String) async throws {
        try await CloudHTTP.send(.post, "/auth/v1/otp", json: ["email": email, "create_user": true], token: nil)
    }

    /// First-time sign-ups are verified as "signup", returning users as "magiclink"; "email" covers both on
    /// current servers. Try them in order so a code works whichever email the server sent.
    func verify(email: String, code: String) async throws {
        var firstError: Error?
        for type in ["email", "signup", "magiclink"] {
            do {
                let (data, _) = try await CloudHTTP.send(.post, "/auth/v1/verify",
                                                         json: ["type": type, "email": email, "token": code], token: nil)
                try adopt(data, fallbackEmail: email)
                return
            } catch let error as CloudError where (400...422).contains(error.status ?? 0) {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? CloudError.invalidResponse
    }

    func signOut() {
        session = nil
        Keychain.delete(account: Self.account)
    }

    /// A valid access token, refreshing it first if it expires within a minute.
    func accessToken() async throws -> String { try await credentials().token }

    func credentials() async throws -> (token: String, userID: UUID) {
        guard let s = session else { throw CloudError.notSignedIn }
        if s.expiresAt.timeIntervalSinceNow > 60 { return (s.accessToken, s.user.id) }
        if let task = refreshTask { let r = try await task.value; return (r.accessToken, r.user.id) }
        let task = Task { try await self.refresh(s) }
        refreshTask = task
        defer { refreshTask = nil }
        let r = try await task.value
        return (r.accessToken, r.user.id)
    }

    private func refresh(_ s: StoredSession) async throws -> StoredSession {
        do {
            let (data, _) = try await CloudHTTP.send(.post, "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                                     json: ["refresh_token": s.refreshToken], token: nil)
            try adopt(data, fallbackEmail: s.user.email)
            guard let fresh = session else { throw CloudError.notSignedIn }
            return fresh
        } catch let error as CloudError where error.status == 400 || error.status == 401 {
            signOut()
            throw CloudError.notSignedIn
        }
    }

    private func adopt(_ data: Data, fallbackEmail: String) throws {
        let r = try JSONDecoder().decode(AuthResponse.self, from: data)
        let stored = StoredSession(accessToken: r.access_token, refreshToken: r.refresh_token,
                                   expiresAt: Date().addingTimeInterval(r.expires_in),
                                   user: CloudUser(id: r.user.id, email: r.user.email ?? fallbackEmail))
        session = stored
        if let encoded = try? JSONEncoder().encode(stored) { Keychain.save(encoded, account: Self.account) }
    }
}

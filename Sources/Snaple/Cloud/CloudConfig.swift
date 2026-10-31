import Foundation

/// Backend endpoints. The publishable key is *designed* to ship inside client apps — it only identifies the
/// project; every row and file is protected by Row Level Security and Storage policies (see Docs/CLOUD.md).
/// Self-hosters can point Snaple at their own Supabase by setting `cloud.url` / `cloud.key` in UserDefaults.
enum CloudConfig {
    static var projectURL: URL {
        if let s = UserDefaults.standard.string(forKey: "cloud.url"), let u = URL(string: s) { return u }
        return URL(string: "https://enbyglzyrjmtqfxmrufx.supabase.co")!
    }

    static var publishableKey: String {
        UserDefaults.standard.string(forKey: "cloud.key") ?? "sb_publishable_xte-8TL5h6grAys7_7Lmjg_q1_uoqlC"
    }

    static let bucket = "captures"

    static func shareURL(token: String) -> URL {
        projectURL.appendingPathComponent("functions/v1/s/\(token)")
    }
}

enum CloudError: LocalizedError {
    case notSignedIn
    case server(status: Int, message: String)
    case invalidResponse
    case encoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to use Snaple Cloud."
        case .server(let status, let message): return message.isEmpty ? "Server error (\(status))." : message
        case .invalidResponse: return "Unexpected response from the server."
        case .encoding: return "Could not prepare the image for upload."
        }
    }

    var status: Int? { if case .server(let s, _) = self { return s }; return nil }
}

import Foundation

enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

/// Thin URLSession wrapper for Supabase's REST endpoints. Ephemeral session: no cookies, no disk cache,
/// no credential storage beyond what we put in the Keychain ourselves.
enum CloudHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 900
        c.httpAdditionalHeaders = ["User-Agent": "Snaple-macOS/0.1"]
        return URLSession(configuration: c)
    }()

    @discardableResult
    static func send(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [],
                     headers: [String: String] = [:], body: Data? = nil, json: Any? = nil,
                     token: String?) async throws -> (data: Data, response: HTTPURLResponse) {
        guard var comps = URLComponents(string: CloudConfig.projectURL.absoluteString + path) else { throw CloudError.invalidResponse }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw CloudError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        var payload = body
        if let json {
            payload = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, resp): (Data, URLResponse)
        if let payload { (data, resp) = try await session.upload(for: req, from: payload) }
        else { (data, resp) = try await session.data(for: req) }

        guard let http = resp as? HTTPURLResponse else { throw CloudError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.server(status: http.statusCode, message: errorMessage(from: data))
        }
        return (data, http)
    }

    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["msg", "message", "error_description", "error"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        return ""
    }
}

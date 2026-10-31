import CoreGraphics
import Foundation

struct CloudCapture: Decodable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let storagePath: String
    let thumbPath: String?
    let contentType: String
    let width: Int
    let height: Int
    let scale: Double
    let bytes: Int64
    var ocrText: String?
    var shareToken: String?
    var shareExpiresAt: Date?
    let createdAt: Date

    var shareURL: URL? {
        guard let shareToken else { return nil }
        if let shareExpiresAt, shareExpiresAt <= Date() { return nil }
        return CloudConfig.shareURL(token: shareToken)
    }
}

enum SupabaseDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// Postgres emits microseconds; trim to milliseconds so ISO8601DateFormatter accepts it.
    static func parse(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression)
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }

    static func string(_ d: Date) -> String { fractional.string(from: d) }
}

/// Storage + database + sharing calls. Everything runs as the signed-in user; Row Level Security decides
/// what they can touch, so a bug here can't expose another user's data.
final class CloudAPI {
    static let shared = CloudAPI()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = SupabaseDate.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    private func auth() async throws -> (token: String, uid: UUID) {
        let c = try await CloudSession.shared.credentials()
        return (c.token, c.userID)
    }

    // MARK: Upload

    /// Uploads the *flattened* image (annotations and redactions already baked in) plus a small thumbnail.
    /// OCR runs on that same flattened image, so text you redacted can never leak into search metadata.
    func upload(image: CGImage, scale: CGFloat, id: UUID, createdAt: Date, name: String, format: ImageFormat) async throws -> CloudCapture {
        let (token, uid) = try await auth()
        guard let data = ImageEncoder.data(for: image, scale: scale, format: format),
              let thumb = ImageOps.thumbnailJPEG(image, maxPixel: 480) else { throw CloudError.encoding }

        let ext = format.fileExtension
        let path = "\(uid.uuidString.lowercased())/\(id.uuidString.lowercased()).\(ext)"
        let thumbPath = "\(uid.uuidString.lowercased())/\(id.uuidString.lowercased())_thumb.jpg"
        let mime = format == .png ? "image/png" : "image/jpeg"

        try await putObject(path, data: data, contentType: mime, token: token)
        try await putObject(thumbPath, data: thumb, contentType: "image/jpeg", token: token)

        let ocr = Preferences.indexText ? try? await Recognizer.text(in: image) : nil
        var row: [String: Any] = [
            "id": id.uuidString.lowercased(), "name": name, "storage_path": path, "thumb_path": thumbPath,
            "content_type": mime, "width": image.width, "height": image.height, "scale": Double(scale),
            "bytes": data.count, "created_at": SupabaseDate.string(createdAt),
        ]
        row["ocr_text"] = (ocr?.isEmpty == false) ? ocr : NSNull()

        do {
            let (resp, _) = try await CloudHTTP.send(.post, "/rest/v1/captures", headers: ["Prefer": "return=representation"], json: row, token: token)
            return try firstRow(resp)
        } catch let e as CloudError where e.status == 409 {
            // Already uploaded (e.g. re-uploading after editing): update the mutable columns only.
            var patch = row
            for k in ["id", "created_at"] { patch.removeValue(forKey: k) }
            let (resp, _) = try await CloudHTTP.send(.patch, "/rest/v1/captures", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                                                     headers: ["Prefer": "return=representation"], json: patch, token: token)
            return try firstRow(resp)
        } catch {
            try? await deleteObjects([path, thumbPath], token: token)   // don't leave orphaned files behind
            throw error
        }
    }

    private func putObject(_ path: String, data: Data, contentType: String, token: String) async throws {
        try await CloudHTTP.send(.post, "/storage/v1/object/\(CloudConfig.bucket)/\(path)",
                                 headers: ["Content-Type": contentType, "x-upsert": "true", "Cache-Control": "max-age=3600"],
                                 body: data, token: token)
    }

    private func deleteObjects(_ paths: [String], token: String) async throws {
        try await CloudHTTP.send(.delete, "/storage/v1/object/\(CloudConfig.bucket)", json: ["prefixes": paths], token: token)
    }

    private func firstRow(_ data: Data) throws -> CloudCapture {
        guard let first = try Self.decoder.decode([CloudCapture].self, from: data).first else { throw CloudError.invalidResponse }
        return first
    }

    // MARK: Library

    func list(search: String? = nil, limit: Int = 500) async throws -> [CloudCapture] {
        let (token, _) = try await auth()
        var q = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "created_at.desc"),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let s = search?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            let safe = s.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
            q.append(URLQueryItem(name: "or", value: "(name.ilike.*\(safe)*,ocr_text.ilike.*\(safe)*)"))
        }
        let (data, _) = try await CloudHTTP.send(.get, "/rest/v1/captures", query: q, token: token)
        return try Self.decoder.decode([CloudCapture].self, from: data)
    }

    func rename(id: UUID, to name: String) async throws {
        let (token, _) = try await auth()
        try await CloudHTTP.send(.patch, "/rest/v1/captures", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                                 json: ["name": name], token: token)
    }

    func delete(_ capture: CloudCapture) async throws {
        let (token, _) = try await auth()
        try await deleteObjects([capture.storagePath] + (capture.thumbPath.map { [$0] } ?? []), token: token)
        try await CloudHTTP.send(.delete, "/rest/v1/captures", query: [URLQueryItem(name: "id", value: "eq.\(capture.id.uuidString.lowercased())")], token: token)
    }

    // MARK: Sharing

    /// Creates (or refreshes) the unlisted link. `days == nil` means it never expires.
    func share(id: UUID, expiresInDays days: Int?) async throws -> URL {
        let (token, _) = try await auth()
        let (data, _) = try await CloudHTTP.send(.post, "/rest/v1/rpc/share_capture",
                                                 json: ["p_id": id.uuidString.lowercased(), "p_expires_in_days": days as Any? ?? NSNull()], token: token)
        guard let t = try? JSONDecoder().decode(String.self, from: data) else { throw CloudError.invalidResponse }
        return CloudConfig.shareURL(token: t)
    }

    func unshare(id: UUID) async throws {
        let (token, _) = try await auth()
        try await CloudHTTP.send(.post, "/rest/v1/rpc/unshare_capture", json: ["p_id": id.uuidString.lowercased()], token: token)
    }

    // MARK: Files

    func download(path: String) async throws -> Data {
        let (token, _) = try await auth()
        return try await CloudHTTP.send(.get, "/storage/v1/object/authenticated/\(CloudConfig.bucket)/\(path)", token: token).data
    }
}

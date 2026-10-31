import AppKit

/// The one-click "upload and get a link" flow used by the thumbnail, the editor and auto-upload.
@MainActor
enum CloudUploader {
    /// Uploads `image`, creates an unlisted link (unless `makeLink` is false) and copies it.
    @discardableResult
    static func upload(image: CGImage, scale: CGFloat, id: UUID, createdAt: Date, makeLink: Bool = true) async -> URL? {
        guard CloudSession.shared.isSignedIn else {
            Toast.show("Sign in to upload", symbol: "person.crop.circle.badge.exclamationmark")
            LibraryWindowController.shared.show(signIn: true)
            return nil
        }
        Toast.show("Uploading…", symbol: "icloud.and.arrow.up")
        do {
            let name = CaptureStore.shared.list().first { $0.id == id }?.name ?? Output.fileName(for: createdAt)
            let saved = try await CloudAPI.shared.upload(image: image, scale: scale, id: id, createdAt: createdAt, name: name, format: .png)
            guard makeLink else { Toast.show("Saved to Snaple Cloud", symbol: "icloud.fill"); return nil }
            let url = try await CloudAPI.shared.share(id: saved.id, expiresInDays: Preferences.linkExpiryDays)
            Output.copyText(url.absoluteString)
            Toast.show("Link copied", symbol: "link")
            return url
        } catch {
            Toast.show("Upload failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }
}

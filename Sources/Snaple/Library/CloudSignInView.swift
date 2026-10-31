import SwiftUI

enum EmailValidator {
    static func isValid(_ s: String) -> Bool {
        s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
}

/// Plain-language messages for the errors a person can actually act on.
enum SignInMessage {
    static func friendly(_ error: Error) -> String {
        if error is URLError { return "Can't reach Snaple Cloud. Check your internet connection and try again." }
        let text = error.localizedDescription.lowercased()
        if text.contains("rate limit") || text.contains("too many") || text.contains("after") && text.contains("second") {
            return "Too many emails requested. Wait a minute and try again."
        }
        if text.contains("expired") || text.contains("invalid") || text.contains("incorrect") {
            return "That code is incorrect or has expired. Check the newest email, or request a new code."
        }
        if text.contains("email") && text.contains("address") { return "That email address doesn't look right." }
        return error.localizedDescription
    }
}

/// Create an account or sign in with one flow: email → 6-digit code. There is no password and no separate
/// "sign up" screen — a new email simply gets an account the first time it's verified.
struct CloudSignInView: View {
    @ObservedObject private var session = CloudSession.shared
    var onDone: () -> Void = {}

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?
    @State private var cooldown = 0
    @FocusState private var focus: Field?
    private enum Field { case email, code }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current = session.email {
                signedIn(current)
            } else if codeSent {
                codeStep
            } else {
                emailStep
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focus = .email }
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create your account or sign in").font(.headline)
            Text("Enter your email and we'll send you a 6-digit code. New here? Your account is created automatically. No password needed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Email address", text: $email, prompt: Text("you@example.com"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .disabled(busy)
                .onSubmit { Task { await sendCode() } }
                .accessibilityLabel("Email address")
            HStack {
                Button { Task { await sendCode() } } label: {
                    Text(busy ? "Sending…" : "Continue").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!EmailValidator.isValid(cleanEmail) || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            Text("By continuing you agree that your uploads are stored in your account. You can delete them any time.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your email").font(.headline)
            Text("We sent a 6-digit code to **\(cleanEmail)**. It can take a minute, and it may land in spam.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("6-digit code", text: $code, prompt: Text("123456"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(.title3, design: .monospaced))
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .disabled(busy)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    if digits.count == 6 { Task { await verify() } }     // submit as soon as it's complete
                }
                .accessibilityLabel("6-digit code")
            HStack(spacing: 12) {
                Button { Task { await verify() } } label: { Text(busy ? "Checking…" : "Verify").frame(minWidth: 80) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count < 6 || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 14) {
                Button(cooldown > 0 ? "Resend code in \(cooldown)s" : "Resend code") { Task { await sendCode() } }
                    .disabled(cooldown > 0 || busy)
                Button("Use a different email") { codeSent = false; code = ""; error = nil; focus = .email }
            }
            .buttonStyle(.link).font(.callout)
        }
    }

    private func signedIn(_ current: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signed in as \(current)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Uploads and share links are tied to this account.").font(.callout).foregroundStyle(.secondary)
            Button("Sign Out") { session.signOut(); code = ""; codeSent = false; onDone() }
        }
    }

    // MARK: Actions

    private func sendCode() async {
        guard EmailValidator.isValid(cleanEmail) else { error = "Enter a valid email address."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await session.sendCode(to: cleanEmail)
            code = ""
            codeSent = true
            focus = .code
            startCooldown()
        } catch {
            self.error = SignInMessage.friendly(error)
        }
    }

    private func verify() async {
        guard code.count == 6, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await session.verify(email: cleanEmail, code: code)
            Toast.show("Signed in as \(cleanEmail)", symbol: "checkmark.circle.fill")
            onDone()
        } catch {
            self.error = SignInMessage.friendly(error)
            code = ""
            focus = .code
        }
    }

    private func startCooldown() {
        cooldown = 30
        Task {
            while cooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                cooldown -= 1
            }
        }
    }
}

import SwiftUI
import CommonThreadKit

struct AccountSignInView: View {
    let baseURL: URL
    let connected: (LoginCredential) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sign in with the same email you use on the web and Chrome. Your iPhone finds stay here; you can choose the shared Library in Profile.")
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(sent || busy)
                        .accessibilityIdentifier("loginEmail")
                    if sent {
                        TextField("Code from your email", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                            .disabled(busy).accessibilityIdentifier("loginCode")
                    }
                    Button(sent ? "Sign in" : "Email me a code") { Task { await submit() } }
                        .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (sent && code.isEmpty))
                        .accessibilityIdentifier("submitLogin")
                    if sent { Button("Use another email") { sent = false; code = ""; message = nil }.disabled(busy) }
                    if busy { ProgressView() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("Your sign-in stays in iPhone Keychain. Existing local finds stay on this phone until you choose to copy them.")
                }
            }
            .navigationTitle("Sign in to Mymah").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
    }
    private func submit() async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            let auth = try NeonSessionClient(baseURL: baseURL)
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if sent {
                let credential = try await auth.signIn(email: address, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                code = ""
                try await connected(credential)
                dismiss()
            } else {
                try await auth.sendCode(email: address)
                sent = true; message = "Check your inbox for a sign-in code."
            }
        } catch { message = error.localizedDescription }
    }
}

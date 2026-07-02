import SwiftUI

struct SignInSheet: View {
    let host: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""

    private var isBitbucket: Bool { host.lowercased().contains("bitbucket") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(host)")
                .font(.title3).bold()
            Text(isBitbucket
                 ? "Paste a Bitbucket access token, or an app password as user:app_password. Stored only in this app's keychain entry — never used by /usr/bin/git's credential helper."
                 : "Paste a Personal Access Token. Stored only in this app's keychain entry — never used by /usr/bin/git's credential helper.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if host.lowercased() == "github.com" {
                Link("Create a token →",
                     destination: URL(string: "https://github.com/settings/tokens?type=beta")!)
                    .font(.callout)
            } else if isBitbucket {
                Link("Create an app password →",
                     destination: URL(string: "https://bitbucket.org/account/settings/app-passwords/")!)
                    .font(.callout)
            }

            SecureField(isBitbucket ? "Access token or user:app_password" : "Personal Access Token", text: $token)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Sign in") {
                    onSave(token)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

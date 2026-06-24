import Foundation

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var account: GitAccount?
    @Published var hasStoredToken: Bool = false

    private let git: GitRepository
    private let credentials: CredentialRepository
    private let main: MainViewModel
    private let repoSource: () -> Repository?

    init(
        git: GitRepository,
        credentials: CredentialRepository,
        main: MainViewModel,
        repoSource: @escaping () -> Repository?
    ) {
        self.git = git
        self.credentials = credentials
        self.main = main
        self.repoSource = repoSource
    }

    func repositoryDidChange() {
        account = nil
        hasStoredToken = false
    }

    func refreshAccount() async {
        guard let repo = repoSource() else {
            account = nil
            hasStoredToken = false
            return
        }
        let acc = await git.account(at: repo.url)
        account = acc
        hasStoredToken = acc.host.map { credentials.hasToken(host: $0) } ?? false
    }

    func signIn(token: String) {
        guard let host = account?.host else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        credentials.setToken(trimmed, host: host)
        hasStoredToken = true
    }

    func signOut() {
        guard let host = account?.host else { return }
        credentials.delete(host: host)
        hasStoredToken = false
    }

    func switchRemote(to transport: RemoteTransport) async {
        guard let repo = repoSource(),
              let acc = account,
              let host = acc.host,
              let owner = acc.owner,
              let name = acc.repo else { return }
        let newURL: String
        switch transport {
        case .ssh:   newURL = "git@\(host):\(owner)/\(name).git"
        case .https: newURL = "https://\(host)/\(owner)/\(name).git"
        default: return
        }
        do {
            try await git.setRemoteURL(newURL, name: "origin", at: repo.url)
            await refreshAccount()
        } catch {
            main.errorMessage = error.localizedDescription
        }
    }

    /// Returns an auth override only when remote is HTTPS and a PAT is stored.
    func currentAuth() -> AuthOverride? {
        guard let host = account?.host,
              let url = account?.remoteURL,
              url.lowercased().hasPrefix("https://"),
              let token = credentials.token(host: host) else { return nil }
        return AuthOverride(bearerToken: token)
    }
}

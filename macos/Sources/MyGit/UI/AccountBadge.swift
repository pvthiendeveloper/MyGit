import SwiftUI

struct AccountBadge: View {
    @EnvironmentObject var account: AccountViewModel
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            avatar
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(account.account == nil)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AccountPopover().environmentObject(account)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = account.account?.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().interpolation(.high)
                default:
                    Image(systemName: "person.crop.circle").font(.system(size: 26))
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        }
    }
}

private struct AccountPopover: View {
    @EnvironmentObject var account: AccountViewModel
    @State private var showTokenSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            grid
            Divider()
            authSection
            if let url = account.account?.webURL {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open on \(account.account?.host ?? "remote")", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(width: 360)
        .sheet(isPresented: $showTokenSheet) {
            SignInSheet(host: account.account?.host ?? "github.com") { token in
                account.signIn(token: token)
            }
        }
    }

    @ViewBuilder
    private var authSection: some View {
        if let acc = account.account, let host = acc.host {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: iconName(acc))
                        .foregroundStyle(iconColor(acc))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(acc, host: host))
                            .font(.system(size: 12, weight: .medium))
                        Text(subtitle(acc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing(acc)
                }
                // SSH remotes authenticate git via keys, but opening a pull
                // request goes through the host's REST API and needs a stored
                // token. HTTPS remotes reuse their sign-in token, so only show
                // this extra affordance for SSH on PR-capable hosts.
                if acc.isSSH, PullRequestRouter.supports(host: host) {
                    pullRequestTokenRow(host)
                }
            }
        }
    }

    @ViewBuilder
    private func pullRequestTokenRow(_ host: String) -> some View {
        HStack {
            Image(systemName: account.hasStoredToken ? "checkmark.seal.fill" : "arrow.triangle.pull")
                .foregroundStyle(account.hasStoredToken ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pull request access")
                    .font(.system(size: 12, weight: .medium))
                Text(account.hasStoredToken
                     ? "Token stored for \(host)"
                     : "Add a token to open pull requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if account.hasStoredToken {
                Button("Remove") { account.signOut() }
                    .buttonStyle(.bordered)
            } else {
                Button("Add token…") { showTokenSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func iconName(_ a: GitAccount) -> String {
        if a.isSSH { return "key.fill" }
        if a.isHTTPS && account.hasStoredToken { return "checkmark.shield.fill" }
        if a.isHTTPS { return "exclamationmark.shield" }
        return "questionmark.circle"
    }

    private func iconColor(_ a: GitAccount) -> Color {
        if a.isSSH { return .green }
        if a.isHTTPS && account.hasStoredToken { return .green }
        if a.isHTTPS { return .orange }
        return .secondary
    }

    private func title(_ a: GitAccount, host: String) -> String {
        if a.isSSH { return "Authenticated via SSH" }
        if a.isHTTPS && account.hasStoredToken { return "Signed in to \(host)" }
        if a.isHTTPS { return "Not signed in" }
        return "Unknown transport"
    }

    private func subtitle(_ a: GitAccount) -> String {
        if a.isSSH { return "ssh-agent / ~/.ssh keys" }
        if a.isHTTPS && account.hasStoredToken { return "Token stored in your keychain" }
        if a.isHTTPS { return "Fetch/pull/push will prompt for keychain access" }
        return a.remoteURL ?? ""
    }

    @ViewBuilder
    private func trailing(_ a: GitAccount) -> some View {
        if a.isSSH {
            EmptyView()
        } else if a.isHTTPS && account.hasStoredToken {
            Button("Sign out") { account.signOut() }
                .buttonStyle(.bordered)
        } else if a.isHTTPS {
            Button("Sign in…") { showTokenSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            if let url = account.account?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().interpolation(.high)
                    default: Image(systemName: "person.crop.circle").font(.system(size: 36))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(account.account?.owner ?? account.account?.userName ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                if let host = account.account?.host {
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Author", account.account?.userName)
            row("Email", account.account?.userEmail)
            row("Remote", account.account?.remoteURL, mono: true)
            if let owner = account.account?.owner, let repo = account.account?.repo {
                row("Repo", "\(owner)/\(repo)", mono: true)
            }
            if let t = account.account?.transport {
                HStack(alignment: .firstTextBaseline) {
                    Text("Transport")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(transportLabel(t))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(transportColor(t))
                    Spacer()
                    if let acc = account.account, (acc.isHTTPS || acc.isSSH),
                       acc.owner != nil, acc.repo != nil {
                        Button(acc.isHTTPS ? "Switch to SSH" : "Switch to HTTPS") {
                            Task {
                                await account.switchRemote(to: acc.isHTTPS ? .ssh : .https)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func transportLabel(_ t: RemoteTransport) -> String {
        switch t {
        case .ssh:   return "SSH"
        case .https: return "HTTPS"
        case .http:  return "HTTP"
        case .git:   return "git://"
        case .local: return "Local"
        case .unknown: return "Unknown"
        }
    }

    private func transportColor(_ t: RemoteTransport) -> Color {
        switch t {
        case .ssh:   return .green
        case .https, .http: return .orange
        default:     return .secondary
        }
    }

    private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value ?? "—")
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

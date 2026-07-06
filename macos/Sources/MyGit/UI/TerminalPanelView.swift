import SwiftUI
import SwiftTerm

/// VS Code-style bottom terminal panel: a tab strip over one live shell view.
struct TerminalPanelView: View {
    @EnvironmentObject var terminal: TerminalViewModel
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ZStack {
                Color(NSColor.textBackgroundColor)
                if let active = terminal.active {
                    // .id ties the host to the active session so switching tabs
                    // swaps in that session's persistent terminal view.
                    TerminalHostView(session: active)
                        .id(active.id)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(terminal.sessions) { session in
                        TerminalTab(
                            session: session,
                            isActive: session.id == terminal.activeID,
                            onSelect: { terminal.select(session.id) },
                            onClose: { terminal.close(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Button {
                terminal.newSession(cwd: coordinator.terminalCWD)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Terminal (⌃⇧`)")
            .padding(.horizontal, 6)

            Button {
                terminal.isVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide Terminal (⌃`)")
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Text(session.title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? Color(NSColor.selectedContentBackgroundColor).opacity(0.35) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Embeds a session's persistent `LocalProcessTerminalView` and gives it first
/// responder on appear so keystrokes go to the shell.
private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
    }
}

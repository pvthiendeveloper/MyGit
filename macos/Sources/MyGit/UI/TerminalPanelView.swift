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

    @ViewBuilder
    private func tabMenu(for session: TerminalSession) -> some View {
        Button("Rename Session…") { rename(session) }
        Divider()
        Button("New Terminal") { terminal.newSession(cwd: coordinator.terminalCWD) }
        Divider()
        Button("Close Tab") { terminal.close(session.id) }
        Button("Close Other Tabs") { terminal.closeOthers(keep: session.id) }
            .disabled(terminal.sessions.count < 2)
        Button("Close All Tabs") { terminal.closeAll() }
        Divider()
        Button("Select Next Tab") { terminal.selectAdjacent(1) }
            .disabled(terminal.sessions.count < 2)
        Button("Select Previous Tab") { terminal.selectAdjacent(-1) }
            .disabled(terminal.sessions.count < 2)
        Divider()
        Button("Hide") { terminal.isVisible = false }
    }

    private func rename(_ session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Leave empty to use the shell's own title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = session.customTitle ?? session.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.rename(to: field.stringValue)
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
                        .contextMenu { tabMenu(for: session) }
                    }
                    // Right after the last tab, like a browser's new-tab button.
                    Button {
                        terminal.newSession(cwd: coordinator.terminalCWD)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("New Terminal (⌃⇧`)")
                }
                .padding(.horizontal, 8)
                .wheelScrollsHorizontally()
            }

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

import SwiftUI
import AppKit

/// Settings ▸ Keyboard Shortcuts: every rebindable command, grouped like the
/// menu bar. Click a shortcut, press the new chord; ⎋ cancels, ⌫ removes it.
struct ShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var recording: ShortcutAction?
    @State private var filter = ""
    /// Feedback for the last change (a stolen chord, a rejected one).
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Text("Click a shortcut and press the new keys. ⎋ cancels, ⌫ removes the shortcut. Assigning a chord that another command uses moves it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                let actions = ShortcutAction.allCases.filter { $0.group == group && matches($0) }
                if !actions.isEmpty {
                    Section(group.rawValue) {
                        ForEach(actions) { action in row(action) }
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        recording = nil
                        shortcuts.resetAll()
                        notice = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { recording = nil }
    }

    private func matches(_ action: ShortcutAction) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return action.title.lowercased().contains(q)
            || action.group.rawValue.lowercased().contains(q)
            || (shortcuts.shortcut(for: action)?.display.lowercased().contains(q) ?? false)
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            ShortcutRecorder(
                shortcut: shortcuts.shortcut(for: action),
                isRecording: Binding(
                    get: { recording == action },
                    set: { recording = $0 ? action : (recording == action ? nil : recording) }
                ),
                onRecord: { assign($0, to: action) }
            )
            Button {
                shortcuts.reset(action)
                notice = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Restore default (\(action.defaultShortcut?.display ?? "none"))")
            .opacity(shortcuts.isCustomized(action) ? 1 : 0)
            .disabled(!shortcuts.isCustomized(action))
        }
    }

    private func assign(_ shortcut: KeyShortcut?, to action: ShortcutAction) {
        guard let shortcut else {
            shortcuts.set(nil, for: action)
            notice = nil
            return
        }
        guard shortcut.isValid else {
            notice = "Use at least one of ⌘, ⌥ or ⌃ (function keys work alone)."
            return
        }
        if let owner = ShortcutSettings.reserved[shortcut] {
            notice = "\(shortcut.display) is reserved for \(owner)."
            return
        }
        let previous = shortcuts.conflict(for: shortcut, excluding: action)
        shortcuts.set(shortcut, for: action)
        notice = previous.map { "\(shortcut.display) was removed from “\($0.title)”." }
    }
}

/// A button that shows a chord and, once clicked, captures the next key-down.
private struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    @Binding var isRecording: Bool
    let onRecord: (KeyShortcut?) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording ? "Press keys…" : (shortcut?.display ?? "None"))
                .font(.system(.body, design: .rounded))
                .foregroundStyle(isRecording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .onChange(of: isRecording) { _, recording in
            recording ? startMonitor() : stopMonitor()
        }
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty, event.keyCode == 53 {                        // ⎋
                isRecording = false
            } else if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {  // ⌫ / ⌦
                onRecord(nil)
                isRecording = false
            } else if let chord = KeyShortcut(event: event) {
                onRecord(chord)
                isRecording = false
            }
            return nil   // swallow — the chord must not also run its command
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

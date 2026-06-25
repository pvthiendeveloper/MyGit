import SwiftUI

struct CommitComposerView: View {
    @EnvironmentObject var vm: ChangesViewModel
    @EnvironmentObject var main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Summary (required)", text: $vm.commitSummary)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.commitMode == .amendKeepMessage)

            TextEditor(text: $vm.commitDescription)
                .font(.system(size: 12))
                .frame(minHeight: 60, maxHeight: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if vm.commitDescription.isEmpty {
                        Text("Description")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(vm.commitMode == .amendKeepMessage)

            HStack(spacing: 6) {
                Button(action: triggerCommit) {
                    Text(commitButtonTitle)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .frame(height: 32)
                .disabled(!vm.canCommit || main.isBusy)

                Menu {
                    Button {
                        vm.setCommitMode(.commit)
                    } label: {
                        Label("Commit", systemImage: vm.commitMode == .commit ? "checkmark" : "")
                    }
                    Button {
                        vm.setCommitMode(.commitAndPush)
                    } label: {
                        Label("Commit & Push", systemImage: vm.commitMode == .commitAndPush ? "checkmark" : "")
                    }
                    Button {
                        vm.setCommitMode(.commitAndForcePush)
                    } label: {
                        Label("Commit & Force Push", systemImage: vm.commitMode == .commitAndForcePush ? "checkmark" : "")
                    }
                    Divider()
                    Button {
                        vm.setCommitMode(.amendKeepMessage)
                    } label: {
                        Label("Amend (keep message)", systemImage: vm.commitMode == .amendKeepMessage ? "checkmark" : "")
                    }
                    .disabled(!vm.canAmend)
                    Button {
                        vm.setCommitMode(.amendUpdateMessage)
                    } label: {
                        Label("Amend (update message)", systemImage: vm.commitMode == .amendUpdateMessage ? "checkmark" : "")
                    }
                    .disabled(!vm.canAmend)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 32)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(main.isBusy)
            }
        }
        .alert(
            "Force push?",
            isPresented: $vm.pendingForcePushConfirm
        ) {
            Button("Commit & Force Push", role: .destructive) {
                Task { await vm.commit() }
            }
            Button("Cancel", role: .cancel) { vm.pendingForcePushConfirm = false }
        } message: {
            Text("Force push rewrites remote history on '\(vm.status?.branch ?? "current branch")' and can overwrite teammates' commits. Continue?")
        }
    }

    private var commitButtonTitle: String {
        let branch = vm.status?.branch ?? ""
        switch vm.commitMode {
        case .commit:
            return branch.isEmpty ? "Commit" : "Commit to \(branch)"
        case .commitAndPush:
            return branch.isEmpty ? "Commit & Push" : "Commit & Push to \(branch)"
        case .commitAndForcePush:
            return branch.isEmpty ? "Commit & Force Push" : "Commit & Force Push to \(branch)"
        case .amendKeepMessage:
            return "Amend (keep message)"
        case .amendUpdateMessage:
            return "Amend (update message)"
        }
    }

    private func triggerCommit() {
        if vm.commitMode == .commitAndForcePush {
            vm.pendingForcePushConfirm = true
        } else {
            Task { await vm.commit() }
        }
    }
}

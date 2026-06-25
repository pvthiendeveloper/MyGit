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
                Button(action: { Task { await vm.commit() } }) {
                    HStack {
                        Spacer()
                        Text(commitButtonTitle).fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canCommit || main.isBusy)

                Menu {
                    Button {
                        vm.setCommitMode(.commit)
                    } label: {
                        Label("Commit", systemImage: vm.commitMode == .commit ? "checkmark" : "")
                    }
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
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(main.isBusy)
            }
        }
    }

    private var commitButtonTitle: String {
        let branch = vm.status?.branch ?? ""
        switch vm.commitMode {
        case .commit:
            return branch.isEmpty ? "Commit" : "Commit to \(branch)"
        case .amendKeepMessage:
            return "Amend (keep message)"
        case .amendUpdateMessage:
            return "Amend (update message)"
        }
    }
}

import SwiftUI

struct CommitComposerView: View {
    @EnvironmentObject var vm: ChangesViewModel
    @EnvironmentObject var main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Summary (required)", text: $vm.commitSummary)
                .textFieldStyle(.roundedBorder)

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
        }
    }

    private var commitButtonTitle: String {
        if let branch = vm.status?.branch {
            return "Commit to \(branch)"
        }
        return "Commit"
    }
}

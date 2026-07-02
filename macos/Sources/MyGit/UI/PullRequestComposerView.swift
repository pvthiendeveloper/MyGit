import AppKit
import SwiftUI

/// Sheet to open a GitHub pull request from the current branch. Prefills the
/// base with the repo's default branch and the title with the branch's last
/// commit subject. On create, opens the PR in the browser.
struct PullRequestComposerView: View {
    let bundle: RepoBundle
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var desc: String = ""
    @State private var base: String = ""
    @State private var loadingBase = true
    @State private var submitting = false

    private var head: String { bundle.remote.pullRequestHead ?? "" }
    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !base.trimmingCharacters(in: .whitespaces).isEmpty
            && !head.isEmpty
            && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Pull Request").font(.headline)

            HStack(spacing: 6) {
                branchChip(head.isEmpty ? "?" : head)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                if loadingBase {
                    ProgressView().controlSize(.small)
                } else {
                    TextField("base", text: $base)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            LabeledContent("Title") {
                TextField("Pull request title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $desc)
                    .font(.system(size: 12))
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(submitting ? "Creating…" : "Create") { submit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await prefill() }
    }

    private func branchChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func prefill() async {
        if title.isEmpty {
            title = bundle.changes.lastCommit?.subject ?? head
        }
        if let def = await bundle.remote.defaultBaseBranch() {
            base = def
        } else if base.isEmpty {
            base = "main"
        }
        loadingBase = false
    }

    private func submit() {
        submitting = true
        Task {
            let url = await bundle.remote.createPullRequest(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: desc,
                base: base.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            submitting = false
            if let url {
                NSWorkspace.shared.open(url)
                dismiss()
            }
        }
    }
}

extension View {
    /// Hosts the Create Pull Request sheet, driven by
    /// `bundle.changes.pendingPullRequest`. Applied in both the single-repo and
    /// multi-repo Changes views so the menu action works everywhere.
    func pullRequestActionHost(_ bundle: RepoBundle) -> some View {
        modifier(PullRequestActionHost(bundle: bundle))
    }
}

private struct PullRequestActionHost: ViewModifier {
    let bundle: RepoBundle
    @ObservedObject private var changes: ChangesViewModel

    init(bundle: RepoBundle) {
        self.bundle = bundle
        self._changes = ObservedObject(wrappedValue: bundle.changes)
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $changes.pendingPullRequest) {
            PullRequestComposerView(bundle: bundle)
        }
    }
}

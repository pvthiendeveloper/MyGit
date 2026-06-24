import SwiftUI

struct DiffView: View {
    let diff: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(diff.path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        DiffLineRow(line: line)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(prefix + line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor)
                .padding(.leading, 6)
                .padding(.vertical, 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var prefix: String {
        switch line.kind {
        case .addition: return "+ "
        case .deletion: return "- "
        case .context:  return "  "
        case .header, .hunkHeader: return ""
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: return Color(.sRGB, red: 0.18, green: 0.55, blue: 0.20, opacity: 1)
        case .deletion: return Color(.sRGB, red: 0.75, green: 0.20, blue: 0.20, opacity: 1)
        case .header:   return .secondary
        case .hunkHeader: return Color(.sRGB, red: 0.30, green: 0.45, blue: 0.75, opacity: 1)
        case .context:  return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.10)
        case .deletion: return Color.red.opacity(0.10)
        case .hunkHeader: return Color.blue.opacity(0.06)
        default: return .clear
        }
    }
}

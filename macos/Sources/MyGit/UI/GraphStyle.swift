import SwiftUI

/// Stable lane colors for the commit graph, indexed by `GraphRow.colorIndex`.
enum GraphPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.69, blue: 0.31),  // green
        Color(red: 0.26, green: 0.55, blue: 0.96),  // blue
        Color(red: 0.96, green: 0.49, blue: 0.20),  // orange
        Color(red: 0.67, green: 0.40, blue: 0.85),  // purple
        Color(red: 0.90, green: 0.30, blue: 0.45),  // pink
        Color(red: 0.20, green: 0.74, blue: 0.74),  // teal
        Color(red: 0.85, green: 0.70, blue: 0.20),  // yellow
        Color(red: 0.55, green: 0.55, blue: 0.60),  // gray
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Inline chip for a ref decorating a commit (branch / remote / tag / HEAD).
struct RefBadge: View {
    let ref: GitRef

    private var tint: Color {
        switch ref.kind {
        case .head: return Color(red: 0.30, green: 0.69, blue: 0.31)
        case .localBranch: return Color(red: 0.26, green: 0.55, blue: 0.96)
        case .remoteBranch: return Color(red: 0.55, green: 0.55, blue: 0.60)
        case .tag: return Color(red: 0.85, green: 0.70, blue: 0.20)
        }
    }

    private var icon: String {
        switch ref.kind {
        case .head: return "smallcircle.filled.circle"
        case .localBranch: return ref.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch"
        case .remoteBranch: return "cloud"
        case .tag: return "tag.fill"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(ref.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
    }
}

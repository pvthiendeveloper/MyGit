import Foundation

/// "Find token": every view on screen whose arguments use a token — by what
/// the source wrote (`tokenProvider.titleToChevronSpacing`) or the design
/// token at its root (`patternGapElementToElement`).
extension UIInspectorViewModel {
    /// A tag's token names, source text and resolved roots, by argument.
    struct TagTokens {
        let tagNodeID: String
        var names: [String]
    }

    /// Recompute matches for `tokenQuery` from the index (cheap; runs per keystroke).
    func updateTokenMatches() {
        let query = tokenQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { tokenMatches = []; return }
        var frames: [String: CGRect] = [:]
        for entry in tokenIndex where entry.names.contains(where: { $0.lowercased().contains(query) }) {
            // Draw the tagged view's box: the first real geometry below the tag.
            if let child = contentChild(entry.tagNodeID), let box = geometry(of: child) { frames[entry.tagNodeID] = box }
        }
        tokenMatches = frames.map { InspectorTokenMatch(tagNodeID: $0.key, frame: $0.value) }
    }

    /// Index the current window's tags: source text at once, roots as they resolve.
    func rebuildTokenIndex() {
        tokenIndexTask?.cancel()
        var index: [TagTokens] = []
        var pending: [(slot: Int, arg: InspectorSourceMapEntry.Argument, stack: [InspectorSourceTag], key: String)] = []
        for tagID in allAnyTagNodeIDs() {
            guard let (_, stack) = chainTag(of: tagID), let tag = stack.first, let entry = sourceEntry(for: tag) else { continue }
            // A root call that's a modifier (`padding(8)` in an extension) is already in `writtenModifiers`.
            let mods = Self.writtenModifiers(entry)
            let args = (mods.count > entry.mods.count ? [] : entry.args) + mods.flatMap(\.args)
            var names: [String] = []
            for arg in args where arg.token {
                names.append(arg.expr)
                let key = "\(tag.id)#\(arg.probe ?? -1)#\(arg.expr)"
                if let root = tokenRootCache[key] { names += root } else { pending.append((index.count, arg, stack, key)) }
            }
            if !names.isEmpty { index.append(TagTokens(tagNodeID: tagID, names: names)) }
        }
        tokenIndex = index
        updateTokenMatches()
        guard !pending.isEmpty else { return }
        tokenIndexTask = Task { @MainActor [weak self] in
            for item in pending {
                guard let self, !Task.isCancelled else { return }
                let resolution = await self.resolveTokenExactly(item.arg.expr, refs: item.arg.refs, binding: item.arg.binding,
                                                                probe: item.arg.probe, stack: item.stack, runtimeValue: nil)
                var roots: [String] = []
                if let root = resolution?.chain?.root.name { roots.append(root) }
                roots += resolution?.alternatives.map(\.name) ?? []
                self.tokenRootCache[item.key] = roots
                if item.slot < self.tokenIndex.count { self.tokenIndex[item.slot].names += roots }
            }
            self?.updateTokenMatches()
        }
    }
}

/// A view matched by "Find token".
struct InspectorTokenMatch: Identifiable {
    let tagNodeID: String
    let frame: CGRect
    var id: String { tagNodeID }
}

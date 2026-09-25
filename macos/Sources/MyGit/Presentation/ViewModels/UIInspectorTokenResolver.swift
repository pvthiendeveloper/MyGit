import Foundation

/// Token chains resolved the way the compiler resolved them: every name is
/// looked up at its exact source position in the index store of the "Run
/// with Inspector" build (`.mygit/inspect/DerivedData`), so
/// `tokenProvider.labelToValueSpacing` means the declaration the compiler
/// bound — for a protocol requirement, its actual implementations — never a
/// same-named property elsewhere. Values come from the tagger's property
/// index (`_symbols.json`), keyed by the declaration's file and name.
///
/// Bare names (`style`, `label`) are parameters or stored properties, which
/// the index doesn't record; they're traced through the runtime tag stack
/// to the call that created this view instance, using the tagged view's
/// scope (`labelText(style:)`'s parameter, `FloatingLabel`'s property).
extension UIInspectorViewModel {
    /// nil when no inspect build/index is available (caller falls back).
    func resolveTokenExactly(_ expr: String, refs: [[InspectorRef]]?, binding: String? = nil,
                             stack: [InspectorSourceTag], runtimeValue: String?) async -> InspectorTokenResolution? {
        guard let first = stack.first, let navigator = sourceNavigator,
              let inspect = navigator.inspectDirectory(forRelativePath: first.path) else { return nil }
        let store = inspect.appendingPathComponent("DerivedData/Index.noindex/DataStore")
        let mirror = XcodeSymbolIndex.canonical(inspect.appendingPathComponent("src").path)
        let symbols = symbolsByFile(near: first)

        // 1. Trace a bare name to the argument that supplied it.
        var steps = [expr]
        // A local (`uiImage`) is followed through what it was bound to.
        if let binding { steps.append("let \(expr) = \(binding)") }
        var current = (expr: binding ?? expr, refs: refs, level: 0)
        var hops = 0
        while Self.isIdentifier(current.expr), hops < 8, let entry = sourceEntry(for: stack[current.level]) {
            hops += 1
            guard let supplied = suppliedArgument(named: current.expr, scope: entry.scope, stack: stack,
                                                  from: current.level) else { break }
            steps.append("\(supplied.call)(\(supplied.label.map { "\($0):" } ?? "_:")) \(supplied.arg.expr)")
            current = (supplied.arg.expr, supplied.arg.refs, supplied.level)
        }
        let file = stack[current.level].path
        guard let alternatives = current.refs, !alternatives.isEmpty else {
            return steps.count > 1 ? InspectorTokenResolution(steps: steps, chain: nil, alternatives: [], exact: true) : nil
        }

        // 2. Follow each alternative through the index.
        var chains: [[InspectorSymbol]] = []
        for fallbacks in alternatives {
            chains += await follow(fallbacks, in: file, store: store, mirror: mirror, symbols: symbols, depth: 0)
        }
        let complete = chains.filter { $0.last?.literal != nil }
        guard !chains.isEmpty else {
            return steps.count > 1 ? InspectorTokenResolution(steps: steps, chain: nil, alternatives: [], exact: true) : nil
        }

        // 3. One root, or the one the screen shows, or every possible root.
        var roots: [String: [InspectorSymbol]] = [:]
        for chain in complete { roots["\(chain.last!.path):\(chain.last!.line)"] = chain }
        if roots.count == 1, let only = roots.values.first {
            return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: only), alternatives: [], exact: true)
        }
        if let runtimeValue {
            let matching = roots.values.filter { chain in
                let literal = chain.last!.literal!
                if let wanted = Double(runtimeValue), let value = Double(literal) { return value == wanted }
                return literal == "\"\(runtimeValue)\""
            }
            if matching.count == 1 {
                return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: matching[0]), alternatives: [], exact: true)
            }
        }
        if roots.count > 1 {
            var sorted = roots.values.map { $0.last! }.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            // The app said which `return` ran for this value.
            if let ran = runtimeBranch(among: sorted, value: runtimeValue),
               let chain = roots["\(ran.path):\(ran.line)"] {
                return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: chain), alternatives: [],
                                                exact: true, pickedBy: .runtimeBranch)
            }
            // Roots that can't draw what's on screen are out.
            if let runtimeValue {
                sorted = InspectorBranchPruner.prune(sorted, value: runtimeValue)
                if sorted.count == 1, let chain = roots["\(sorted[0].path):\(sorted[0].line)"] {
                    return InspectorTokenResolution(steps: steps, chain: InspectorTokenChain(hops: chain), alternatives: [],
                                                    exact: true, pickedBy: .screenValue)
                }
            }
            return InspectorTokenResolution(steps: steps, chain: nil, alternatives: sorted, exact: true)
        }
        // Reached declarations but no value (e.g. a computed chain): show how far.
        let deepest = chains.max { $0.count < $1.count }
        return InspectorTokenResolution(steps: steps, chain: deepest.map(InspectorTokenChain.init(hops:)), alternatives: [], exact: true)
    }

    /// The argument a caller passed for `name`: a parameter of the tagged
    /// view's function (matched by the call to that function), else a stored
    /// property of its type (matched by that type's initializer).
    private func suppliedArgument(named name: String, scope: InspectorSourceMapEntry.Scope?,
                                  stack: [InspectorSourceTag], from level: Int)
        -> (arg: InspectorSourceMapEntry.Argument, call: String, label: String?, level: Int)? {
        guard let scope else { return nil }
        let callee: String
        let label: String?
        var position: Int?
        if let function = scope.function, let parameters = scope.parameters,
           let index = parameters.firstIndex(where: { $0.name == name }) {
            callee = function
            label = parameters[index].label
            position = label == nil ? parameters[..<index].filter { $0.label == nil }.count : nil
        } else if let type = scope.type {
            callee = type
            label = name
        } else {
            return nil
        }
        for next in (level + 1)..<max(level + 1, stack.count) {
            guard let entry = sourceEntry(for: stack[next]), entry.call == callee else { continue }
            let arg: InspectorSourceMapEntry.Argument?
            if let label {
                arg = entry.args.first { $0.label == label }
            } else {
                arg = position.flatMap { p in
                    let unlabeled = entry.args.filter { $0.label == nil }
                    return p < unlabeled.count ? unlabeled[p] : nil
                }
            }
            if let arg { return (arg, callee, label, next) }
            return nil   // The right call, but defaulted: nothing more to learn.
        }
        return nil
    }

    /// Resolve one alternative's candidates in order; the first name that the
    /// index binds to a declaration in the repo decides.
    private func follow(_ fallbacks: [InspectorRef], in path: String, store: URL, mirror: String,
                        symbols: [String: [InspectorSymbol]], depth: Int) async -> [[InspectorSymbol]] {
        guard depth < 12 else { return [] }
        for ref in fallbacks {
            guard let resolved = await XcodeSymbolIndex.shared.resolveReference(
                store: store, file: mirror + "/" + path, line: ref.line, column: ref.column, name: ref.name
            ) else { continue }
            // A protocol requirement: what actually runs is an implementation.
            let targets = resolved.implementations.isEmpty ? resolved.declarations : resolved.implementations
            let inRepo = targets.filter { $0.file.hasPrefix(mirror + "/") }
            guard !inRepo.isEmpty else { continue }             // SDK / unindexed: try the next name
            var chains: [[InspectorSymbol]] = []
            for decl in inRepo {
                let relative = String(decl.file.dropFirst(mirror.count + 1))
                let name = decl.name.split(separator: "(").first.map(String.init) ?? decl.name
                let values = Self.values(of: name, declaredAt: decl.line, in: relative, symbols: symbols)
                if values.isEmpty {
                    // Declared, value unknown (logic, SDK types): the chain ends here.
                    chains.append([InspectorSymbol(name: name, owner: nil, path: relative, line: decl.line,
                                                   expr: "", literal: nil)])
                    continue
                }
                for value in values {
                    if value.literal != nil || value.refs == nil {
                        chains.append([value])
                    } else {
                        var deeper: [[InspectorSymbol]] = []
                        for alternative in value.refs ?? [] {
                            deeper += await follow(alternative, in: relative, store: store, mirror: mirror,
                                                   symbols: symbols, depth: depth + 1)
                        }
                        chains += deeper.isEmpty ? [[value]] : deeper.map { [value] + $0 }
                    }
                }
            }
            return chains
        }
        return []
    }

    /// The indexed values of the declaration the index reported: a
    /// property's (its own line) or a function's/getter's returns (whose
    /// `declLine` is that line).
    private static func values(of name: String, declaredAt line: Int, in path: String,
                               symbols: [String: [InspectorSymbol]]) -> [InspectorSymbol] {
        (symbols[path] ?? []).filter { $0.name == name && ($0.declLine ?? $0.line) == line }
    }

    /// The root whose `return` the app reported running (the tagger's
    /// branch probes), when every root is probed and the report singles one
    /// out: the one that produced `value`, else the only one that ran at all.
    func runtimeBranch(among roots: [InspectorSymbol], value: String?) -> InspectorSymbol? {
        guard roots.count > 1, roots.allSatisfy({ $0.probed == true }),
              let branches = snapshot?.branches, !branches.isEmpty else { return nil }
        let seen = roots.map { branches["\($0.path):\($0.line)"] ?? [] }
        if let value {
            let produced = roots.indices.filter { seen[$0].contains(value) }
            if produced.count == 1 { return roots[produced[0]] }
            if produced.count > 1 { return nil }
        }
        let ran = roots.indices.filter { !seen[$0].isEmpty }
        return ran.count == 1 ? roots[ran[0]] : nil
    }
}

import Foundation

/// "✨ Pick": when a token has several possible roots and neither the value
/// on screen nor a runtime probe settles it, ask a language model to read
/// the code around each root plus what's on screen and name the likeliest.
/// The answer is labeled a suggestion — it reads code, it doesn't run it.
extension UIInspectorViewModel {
    enum AIPickError: LocalizedError {
        case notConfigured
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No AI provider is set up. Open Settings (⌘,) ▸ AI — Local runs on this Mac."
            case .unreadable(let raw): return "The model's answer couldn't be read: \(raw.prefix(160))"
            }
        }
    }

    var canPickWithAI: Bool { ai != nil && aiConfig != nil }

    /// `resolution.alternatives` narrowed to one by the model; the others
    /// stay listed so a wrong pick is one click away.
    func pickWithAI(token: String, resolution: InspectorTokenResolution, stack: [InspectorSourceTag],
                    runtimeValue: String?, key: String) async throws -> InspectorTokenResolution {
        if let cached = aiPicks[key] { return cached }
        guard let ai, let config = aiConfig?() else { throw AIPickError.notConfigured }
        let options = resolution.alternatives
        let prompt = pickPrompt(token: token, steps: resolution.steps, options: options, stack: stack,
                                runtimeValue: runtimeValue)
        let raw = try await ai.ask(system: Self.pickRules, user: prompt, config: config)
        guard let answer = Self.parsePick(raw), options.indices.contains(answer.choice) else {
            throw AIPickError.unreadable(raw)
        }
        let picked = InspectorTokenResolution(
            steps: resolution.steps, chain: InspectorTokenChain(hops: [options[answer.choice]]),
            alternatives: options, exact: false,
            pickedBy: .ai(confidence: answer.confidence, reason: answer.reason))
        aiPicks[key] = picked
        return picked
    }

    // MARK: - Prompt

    private static let pickRules = """
    You are helping a developer inspect a running iOS app. A value on screen comes from a \
    getter or function with several `return` branches, and you must decide which branch \
    produced it, using the source code and the app's on-screen state.
    Reason about the conditions guarding each branch against the evidence (the value shown, \
    other text on screen). Prefer branches whose result is consistent with the value shown.
    Answer with JSON only, no code fences:
    {"choice": <option number>, "confidence": <0.0-1.0>, "reason": "<one short sentence>"}
    """

    private func pickPrompt(token: String, steps: [String], options: [InspectorSymbol], stack: [InspectorSourceTag],
                            runtimeValue: String?) -> String {
        var out = "Token expression in the view: `\(token)`\n"
        if steps.count > 1 { out += "Traced through: " + steps.joined(separator: " → ") + "\n" }
        if let runtimeValue { out += "Value shown on screen for this view: \"\(runtimeValue)\"\n" }
        if let tag = stack.first, let excerpt = excerpt(tag.path, around: [tag.line], radius: 4) {
            out += "\nThe view is written at \(tag.label):\n```swift\n\(excerpt)\n```\n"
        }
        out += "\nOptions:\n"
        for (i, option) in options.enumerated() {
            out += "[\(i)] \((option.path as NSString).lastPathComponent):\(option.line) — \(option.name) = \(option.literal ?? option.expr)\n"
        }
        // The code around the options, one excerpt per file.
        var lines: [String: [Int]] = [:]
        for option in options { lines[option.path, default: []].append(option.line) }
        for (path, at) in lines.sorted(by: { $0.key < $1.key }) {
            guard let excerpt = excerpt(path, around: at, radius: 14) else { continue }
            out += "\nSource of \(path) (line numbers on the left):\n```swift\n\(excerpt)\n```\n"
        }
        let texts = screenTexts(limit: 60)
        if !texts.isEmpty {
            out += "\nOther text on screen right now, top to bottom:\n" + texts.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        out += "\nWhich option produced the value? JSON only."
        return out
    }

    /// Numbered lines around `lines` in the original file (ranges merged), at most ~200.
    private func excerpt(_ path: String, around lines: [Int], radius: Int) -> String? {
        guard let url = sourceNavigator?.fileURL(forRelativePath: path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let all = text.components(separatedBy: "\n")
        var ranges: [ClosedRange<Int>] = []
        for line in lines.sorted() {
            let r = max(1, line - radius)...min(all.count, line + radius)
            if let last = ranges.last, r.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                ranges.append(r)
            }
        }
        var out: [String] = []
        for r in ranges {
            if !out.isEmpty { out.append("…") }
            for n in r where out.count < 200 { out.append(String(format: "%4d  ", n) + all[n - 1]) }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// Distinct texts in the current window, in tree order.
    private func screenTexts(limit: Int) -> [String] {
        guard let windows = snapshot?.windows, windows.indices.contains(windowIndex) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        func walk(_ node: InspectorNode) {
            guard out.count < limit, !node.isHidden else { return }
            if let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
               seen.insert(text).inserted {
                out.append(String(text.prefix(120)))
            }
            node.children.forEach(walk)
        }
        walk(windows[windowIndex].root)
        return out
    }

    // MARK: - Answer

    static func parsePick(_ raw: String) -> (choice: Int, confidence: Double, reason: String)? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let choice = (json["choice"] as? NSNumber)?.intValue ?? (json["choice"] as? String).flatMap { Int($0) }
        guard let choice else { return nil }
        let confidence = (json["confidence"] as? NSNumber)?.doubleValue ?? 0.5
        return (choice, min(1, max(0, confidence)), (json["reason"] as? String) ?? "")
    }
}

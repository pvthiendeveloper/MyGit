import Foundation

/// A runnable test in a source file: a test class/suite (runs everything in
/// it) or one test function.
struct DiscoveredTest: Equatable {
    enum Framework: Equatable { case xctest, swiftTesting, junit }

    /// 1-based line the ▶ goes on.
    let line: Int
    let framework: Framework
    /// The class / suite (`AmountFormattingTests`); nil for a free Swift Testing function.
    let suite: String?
    /// The function (`testWholeNumbersDropTheFraction`); nil for the whole suite.
    let function: String?
    /// Kotlin/Java package (`com.tymex.ui`), for Gradle's `--tests` filter.
    let package: String?

    var isSuite: Bool { function == nil }
    var title: String { function.map { "\(suite.map { "\($0)." } ?? "")\($0)" } ?? (suite ?? "tests") }
}

/// Finds tests by reading the source (no compiler): XCTest classes and their
/// `test…()` methods, Swift Testing `@Suite`/`@Test`, JUnit `@Test` in Kotlin
/// and Java. Line-based and forgiving — a missed test just has no ▶.
enum TestDiscovery {
    static func tests(in text: String, fileExtension ext: String) -> [DiscoveredTest] {
        // Most files have no tests: skip the line scan.
        guard text.contains("XCTest") || text.contains("@Test") || text.contains("@Suite") else { return [] }
        switch ext.lowercased() {
        case "swift": return swiftTests(text)
        case "kt", "kts", "java": return junitTests(text)
        default: return []
        }
    }

    // MARK: - Swift

    private static func swiftTests(_ text: String) -> [DiscoveredTest] {
        let lines = text.components(separatedBy: "\n")
        var out: [DiscoveredTest] = []
        // Types seen so far with the indentation they were declared at, to find
        // the type a function belongs to (the nearest one less indented).
        var types: [(name: String, indent: Int, xctest: Bool, line: Int)] = []
        var pendingTest = false          // `@Test` on its own line, `func` below
        var pendingSuite = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if line.hasPrefix("//") { continue }
            if line.hasPrefix("@Test") && !line.contains("func ") { pendingTest = true; continue }
            if line.hasPrefix("@Suite") && !line.contains(" struct ") && !line.contains(" class ") { pendingSuite = true; continue }

            if let type = match(line, #"(?:^|\s)(?:final\s+)?(?:class|struct|enum|actor)\s+(\w+)\s*(?::\s*([^{]+))?"#) {
                let name = type[1]
                let inherits = type.count > 2 ? type[2] : ""
                let isXCTest = inherits.range(of: #"\bXCTestCase\b|\w+TestCase\b"#, options: .regularExpression) != nil
                types.removeAll { $0.indent >= indent }
                types.append((name, indent, isXCTest, i + 1))
                if isXCTest {
                    out.append(.init(line: i + 1, framework: .xctest, suite: name, function: nil, package: nil))
                } else if pendingSuite || line.contains("@Suite") {
                    out.append(.init(line: i + 1, framework: .swiftTesting, suite: name, function: nil, package: nil))
                }
                pendingSuite = false
                continue
            }
            guard let fn = match(line, #"func\s+(`[^`]+`|\w+)\s*\("#)?[1] else { continue }
            let owner = types.last { $0.indent < indent }
            let isSwiftTesting = pendingTest || line.contains("@Test")
            pendingTest = false
            if isSwiftTesting {
                out.append(.init(line: i + 1, framework: .swiftTesting, suite: owner?.name, function: fn + "()", package: nil))
                // A plain struct holding @Test functions is a suite too.
                if let owner, !out.contains(where: { $0.line == owner.line }) {
                    out.append(.init(line: owner.line, framework: .swiftTesting, suite: owner.name, function: nil, package: nil))
                }
            } else if let owner, owner.xctest, fn.hasPrefix("test"), line.contains("()") {
                out.append(.init(line: i + 1, framework: .xctest, suite: owner.name, function: fn, package: nil))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    // MARK: - Kotlin / Java

    private static func junitTests(_ text: String) -> [DiscoveredTest] {
        let lines = text.components(separatedBy: "\n")
        let package = lines.lazy.compactMap { match($0.trimmingCharacters(in: .whitespaces), #"^package\s+([\w.]+)"#)?[1] }.first
        var out: [DiscoveredTest] = []
        var classes: [(name: String, indent: Int, line: Int)] = []
        var pendingTest = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if line.hasPrefix("//") || line.hasPrefix("*") { continue }
            if let cls = match(line, #"(?:^|\s)(?:class|object)\s+(\w+)"#), !line.hasPrefix("@") {
                classes.removeAll { $0.indent >= indent }
                classes.append((cls[1], indent, i + 1))
                continue
            }
            if line.hasPrefix("@Test") || line.hasPrefix("@org.junit.Test") || line.hasPrefix("@ParameterizedTest") {
                pendingTest = true
                if !line.contains("fun ") && !line.contains("void ") { continue }
            }
            guard pendingTest else { continue }
            // Kotlin `fun name(` / `fun \`reads like a sentence\`(`; Java `void name(`.
            guard let fn = match(line, #"fun\s+(`[^`]+`|\w+)\s*\("#)?[1] ?? match(line, #"void\s+(\w+)\s*\("#)?[1] else { continue }
            pendingTest = false
            let owner = classes.last { $0.indent < indent }
            out.append(.init(line: i + 1, framework: .junit, suite: owner?.name, function: fn.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                             package: package))
            if let owner, !out.contains(where: { $0.line == owner.line }) {
                out.append(.init(line: owner.line, framework: .junit, suite: owner.name, function: nil, package: package))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    /// Capture groups of the first match (index 0 = whole match); nil if none.
    private static var regexes: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func match(_ text: String, _ pattern: String) -> [String]? {
        lock.lock()
        let cached = regexes[pattern] ?? (try? NSRegularExpression(pattern: pattern))
        regexes[pattern] = cached
        lock.unlock()
        guard let regex = cached,
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

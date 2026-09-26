import XCTest
@testable import SourceTaggerCore

final class SourceTaggerTests: XCTestCase {
    private func tag(_ src: String) -> SourceTagger.Result {
        SourceTagger.tag(source: src, path: "App/V.swift")
    }

    private func tagCount(_ s: String) -> Int {
        s.components(separatedBy: ".preference(key: __MyGitSourceKey.self").count - 1
    }

    func testTagsBodyStatementsAndNestedContainers() {
        let r = tag("""
        import SwiftUI
        struct Row: View {
            var body: some View {
                VStack {
                    Text("Helper").font(.body)
                    Spacer()
                }
                .padding()
            }
        }
        """)
        XCTAssertEqual(r.tagCount, 3)
        XCTAssertTrue(r.output.contains(#"Text("Helper").font(.body).preference(key: __MyGitSourceKey.self, value: "App/V.swift:5:13")"#))
        XCTAssertTrue(r.output.contains(#".padding().preference(key: __MyGitSourceKey.self, value: "App/V.swift:4:9")"#))
        XCTAssertTrue(r.output.contains("fileprivate struct __MyGitSourceKey"))
    }

    func testLineNumbersArePreserved() {
        let src = """
        import SwiftUI
        struct A: View {
            var body: some View {
                HStack {
                    Text("a")
                    Image(systemName: "x")
                }
            }
        }
        """
        let out = tag(src).output.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        // Every original line is still on its line (tags are appended in place).
        for (i, line) in lines.enumerated() {
            XCTAssertTrue(out[i].hasPrefix(line.trimmingCharacters(in: .newlines)) || out[i].contains(line.trimmingCharacters(in: .whitespaces)), "line \(i + 1)")
        }
    }

    func testButtonActionIsNotTaggedButLabelIs() {
        let r = tag("""
        import SwiftUI
        struct B: View {
            var body: some View {
                VStack {
                    Button("Tap") { save() }
                    Button(action: { save() }) { Text("Label") }
                    Button { save() } label: { Image(systemName: "x") }
                }
            }
        }
        """)
        XCTAssertFalse(r.output.contains("save().preference"))
        XCTAssertTrue(r.output.contains(#"Text("Label").preference"#))
        XCTAssertTrue(r.output.contains(#"Image(systemName: "x").preference"#))
    }

    func testToolbarAndAlertAreLeftAlone() {
        let r = tag("""
        import SwiftUI
        struct C: View {
            var body: some View {
                Text("x")
                    .toolbar { ToolbarItem { Button("Done") { } } }
                    .alert("t", isPresented: .constant(true)) { Button("OK") { } }
            }
        }
        """)
        XCTAssertEqual(r.tagCount, 1)
        XCTAssertFalse(r.output.contains("ToolbarItem { Button(\"Done\") { } }.preference"))
        XCTAssertFalse(r.output.contains("Button(\"Done\") { }.preference"))
        XCTAssertFalse(r.output.contains("Button(\"OK\") { }.preference"))
    }

    func testScenesAndNonViewTypesAreSkipped() {
        let r = tag("""
        import SwiftUI
        @main struct App1: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        struct ContentView: View {
            var controller: UIViewController { UIViewController() }
            var body: some View { Text("hi") }
        }
        """)
        XCTAssertEqual(r.tagCount, 1)
        XCTAssertFalse(r.output.contains("ContentView().preference"))
        XCTAssertTrue(r.output.contains(#"Text("hi").preference"#))
    }

    func testIfSwitchForEachAndViewBuilderFunctions() {
        let r = tag("""
        import SwiftUI
        struct D: View {
            let items: [Int]
            var flag = false
            var body: some View {
                List {
                    if flag { Text("on") } else { Text("off") }
                    ForEach(items, id: \\.self) { i in Row(i: i) }
                    switch items.count { case 0: EmptyView() default: header }
                }
            }
            @ViewBuilder func cell() -> some View {
                Text("a")
                Text("b")
            }
            func plain() -> some View {
                let x = 1
                return Text("\\(x)")
            }
            var header: some View { Label("h", systemImage: "x") }
        }
        """)
        for needle in [#"Text("on").preference"#, #"Text("off").preference"#, #"Row(i: __mT(i, "App/V.swift:"#,
                       "EmptyView().preference", #"Text("a").preference"#, #"Text("b").preference"#,
                       #"return Text("\(x)").preference"#, #"Label("h", systemImage: "x").preference"#] {
            XCTAssertTrue(r.output.contains(needle), needle)
        }
        XCTAssertTrue(r.output.contains("header.preference"), "every builder statement is a view")
    }

    func testViewModifierBodyAndCustomContainers() {
        let r = tag("""
        import SwiftUI
        struct M: ViewModifier {
            func body(content: Content) -> some View {
                content.overlay { Badge() }
            }
        }
        struct E: View {
            var body: some View {
                Card { Text("inside") }
                Card(title: "t") { doWork() }
                Wrapper(leading: { Icon() }, onTap: { tapped() })
            }
        }
        """)
        XCTAssertTrue(r.output.contains("Badge().preference"))
        XCTAssertTrue(r.output.contains(#"Text("inside").preference"#))
        XCTAssertFalse(r.output.contains("doWork().preference"))
        XCTAssertTrue(r.output.contains("Icon().preference"))
        XCTAssertFalse(r.output.contains("tapped().preference"))
        XCTAssertFalse(r.output.contains(#"}.preference(key: __MyGitSourceKey.self, value: "App/V.swift:4:9")"#),
                       "content.overlay restyles the incoming view: no tag, so the call site's wins")
    }

    func testFilesWithoutSwiftUIAreUntouched() {
        let src = "import UIKit\nfinal class V: UIView {}\n"
        XCTAssertEqual(tag(src).output, src)
        XCTAssertEqual(tag(src).tagCount, 0)
    }

    func testExplicitReturnBodyTagsOnlyReturnedView() {
        let r = tag("""
        import SwiftUI
        struct F: View {
            var body: some View {
                let t = "x"
                return VStack { Text(t) }
            }
        }
        """)
        XCTAssertEqual(r.tagCount, 2)
    }

    func testSourceMapSeparatesTokensFromHardcodedValues() {
        let r = tag("""
        import SwiftUI
        struct Row: View {
            var body: some View {
                VStack(alignment: .leading, spacing: tokenProvider.fieldToHelperSpacing) {
                    Text("a")
                        .padding(.vertical, 8)
                        .padding(.horizontal, TymeXSwiftUI.spacing2)
                        .frame(maxWidth: .infinity, minHeight: tokens.minHeight)
                        .foregroundColor(Color.red)
                        .background(theme.surface)
                }
            }
        }
        """)
        let stack = r.sourceMap["App/V.swift:4:9"]
        XCTAssertEqual(stack?.call, "VStack")
        XCTAssertEqual(stack?.args.map(\.label), ["alignment", "spacing"])
        XCTAssertEqual(stack?.args.map(\.token), [false, true])
        XCTAssertEqual(stack?.args.last?.expr, "tokenProvider.fieldToHelperSpacing")

        let text = r.sourceMap["App/V.swift:5:13"]
        XCTAssertEqual(text?.call, "Text")
        XCTAssertEqual(text?.mods.map(\.name), ["padding", "padding", "frame", "foregroundColor", "background"])
        XCTAssertEqual(text?.mods[0].args.map(\.token), [false, false], "padding(.vertical, 8) is hardcoded")
        XCTAssertEqual(text?.mods[1].args.map(\.token), [false, true], "TymeXSwiftUI.spacing2 is a token")
        XCTAssertEqual(text?.mods[2].args.map(\.token), [false, true])
        XCTAssertEqual(text?.mods[3].args.map(\.token), [false], "Color.red is hardcoded")
        XCTAssertEqual(text?.mods[4].args.map(\.token), [true])
    }

    func testSymbolIndexRecordsReferencesAndRoots() {
        let symbols = SourceTagger.symbols(source: """
        import SwiftUI
        public extension TymeXSwiftUI {
            static let patternGapGroupTextToGroupText: CGFloat = 4
            static let surface = LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
        }
        extension SwiftUIInputTokenProviding {
            var labelToValueSpacing: CGFloat { TymeXSwiftUI.patternGapGroupTextToGroupText }
            var wrapped: CGFloat { CGFloat(TymeX.spacing1) }
            func color(_ r: Role) -> Color { local }
        }
        """, path: "T.swift")
        let byName = Dictionary(uniqueKeysWithValues: symbols.map { ($0.name, $0) })
        XCTAssertEqual(byName["patternGapGroupTextToGroupText"]?.owner, "TymeXSwiftUI")
        XCTAssertEqual(byName["patternGapGroupTextToGroupText"]?.literal, "4")
        XCTAssertEqual(byName["labelToValueSpacing"]?.owner, "SwiftUIInputTokenProviding")
        XCTAssertEqual(byName["labelToValueSpacing"]?.expr, "TymeXSwiftUI.patternGapGroupTextToGroupText")
        XCTAssertNil(byName["labelToValueSpacing"]?.literal, "a reference is followed, not a root")
        XCTAssertEqual(byName["wrapped"]?.expr, "TymeX.spacing1", "CGFloat(x) unwraps to x")
        XCTAssertNotNil(byName["surface"]?.literal, "a gradient is a root")
        XCTAssertNil(byName["local"], "function bodies aren't indexed")
    }

    func testBuilderStatementsWithLowercaseRootsAndTernariesAreTagged() {
        let r = tag("""
        import SwiftUI
        struct L: View {
            var body: some View {
                VStack {
                    labelText(style: tokens.resting)
                    flag ? AnyView(Text("a")) : AnyView(Text("b"))
                }
            }
            private func labelText(style: TymeXTextStyle) -> some View {
                Text(label).tymeXTextStyle(style)
            }
        }
        """)
        XCTAssertTrue(r.output.contains(#"labelText(style: __mT(tokens.resting, "App/V.swift:5:13", 1)).preference(key: __MyGitSourceKey.self, value: __mS("App/V.swift:5:13"))"#))
        XCTAssertTrue(r.output.contains(#"(flag ? AnyView(Text("a")) : AnyView(Text("b"))).preference"#))
        XCTAssertEqual(r.sourceMap["App/V.swift:5:13"]?.call, "labelText")
        XCTAssertEqual(r.sourceMap["App/V.swift:5:13"]?.args.first?.label, "style")
    }

    func testViewExtensionHelpersDontTagSelf() {
        let r = tag("""
        import SwiftUI
        extension View {
            func cardStyle() -> some View {
                modifier(CardModifier())
            }
            func badge() -> some View {
                self.overlay { Badge() }
            }
        }
        """)
        XCTAssertFalse(r.output.contains("modifier(CardModifier()).preference"))
        XCTAssertFalse(r.output.contains("}.preference(key: __MyGitSourceKey.self, value: \"App/V.swift:7:9\")"))
        XCTAssertTrue(r.output.contains("Badge().preference"), "closures inside are still views of their own")
    }

    func testFunctionReturnsAreIndexedAsAlternatives() {
        let symbols = SourceTagger.symbols(source: """
        extension P {
            func labelColor(_ role: Role) -> Color {
                switch role {
                case .subtle: return TymeXSwiftUI.patternColorTextSubtle
                case .error: return TymeXSwiftUI.patternColorTextError
                }
            }
            func implicit(_ r: Role) -> CGFloat {
                switch r { case .a: TymeX.spacing1 default: TymeX.spacing2 }
            }
        }
        """, path: "P.swift")
        XCTAssertEqual(symbols.filter { $0.name == "labelColor" }.map(\.expr),
                       ["TymeXSwiftUI.patternColorTextSubtle", "TymeXSwiftUI.patternColorTextError"])
        XCTAssertEqual(symbols.filter { $0.name == "implicit" }.map(\.expr), ["TymeX.spacing1", "TymeX.spacing2"])
    }

    func testSourceMapRecordsReferencePositionsAndScope() {
        let r = tag("""
        import SwiftUI
        struct FloatingLabel: View {
            let label: String
            var body: some View {
                VStack(spacing: tokenProvider.labelToValueSpacing) { labelText(style: tokens.resting) }
            }
            private func labelText(style: TymeXTextStyle) -> some View {
                Text(label)
                    .foregroundColor(tokenProvider.labelColor(state.labelColor))
                    .frame(height: on ? Consts.big : Consts.small)
                    .background(Capsule().fill(TymeXSwiftUI.surface))
            }
        }
        """)
        let stack = r.sourceMap["App/V.swift:5:9"]
        XCTAssertEqual(stack?.args.first?.refs, [[SourceRef(name: "labelToValueSpacing", line: 5, column: 39),
                                                  SourceRef(name: "tokenProvider", line: 5, column: 25)]],
                       "the member first, its base as the fallback")
        XCTAssertEqual(stack?.scope?.type, "FloatingLabel")
        XCTAssertNil(stack?.scope?.function, "body is a property")

        let text = r.sourceMap["App/V.swift:8:9"]
        XCTAssertEqual(text?.scope?.function, "labelText")
        XCTAssertEqual(text?.scope?.parameters?.first?.name, "style")
        XCTAssertEqual(text?.scope?.parameters?.first?.label, "style")
        let color = text?.mods.first { $0.name == "foregroundColor" }?.args.first?.refs
        XCTAssertEqual(color?.first?.first?.name, "labelColor", "the called function comes first")
        let height = text?.mods.first { $0.name == "frame" }?.args.first?.refs
        XCTAssertEqual(height?.map { $0.first?.name }, ["big", "small"], "ternary branches are alternatives")
        let fill = text?.mods.first { $0.name == "background" }?.args.first?.refs?.first?.map(\.name)
        XCTAssertEqual(fill?.first, "fill")
        XCTAssertTrue(fill?.contains("surface") == true, "falls back to what the call is built from")
    }

    func testLocalBindingsPointRefsAtTheirInitializer() {
        let r = tag("""
        import SwiftUI
        struct H: View {
            var body: some View {
                if let uiImage = UIImage(named: Constants.errorIconAssetName, in: Bundle.main, compatibleWith: nil) {
                    Image(uiImage: uiImage)
                }
            }
        }
        """)
        let image = r.sourceMap["App/V.swift:5:13"]?.args.first
        XCTAssertEqual(image?.binding, "UIImage(named: Constants.errorIconAssetName, in: Bundle.main, compatibleWith: nil)")
        XCTAssertEqual(image?.refs?.first?.first?.name, "errorIconAssetName")
    }

    func testStrippedModifiersVanishWithoutMovingLines() {
        let src = """
        import SwiftUI
        struct D: View {
            var body: some View {
                VStack {
                    Text("a")
                        .debugLayoutBounds(level: .element)
                        .padding()
                }
                .debugLayoutBounds(
                    level: .container
                )
            }
        }
        """
        let r = SourceTagger.tag(source: src, path: "App/V.swift", stripModifiers: ["debugLayoutBounds"])
        XCTAssertFalse(r.output.contains("debugLayoutBounds"))
        let before = src.split(separator: "\n", omittingEmptySubsequences: false)
        let after = r.output.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(after[6].contains(".padding()"), "lines after a stripped call stay put")
        XCTAssertTrue(after[11].contains("}"))
        XCTAssertEqual(before[11], after[11])
        XCTAssertEqual(r.sourceMap["App/V.swift:5:13"]?.mods.map(\.name), ["padding"])
    }

    func testMirrorIsIncrementalAndKeepsMtime() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tagger-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src.appendingPathComponent("A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("Pods/X"), withIntermediateDirectories: true)
        try "import SwiftUI\nstruct V: View { var body: some View { Text(\"a\") } }\n"
            .write(to: src.appendingPathComponent("A/V.swift"), atomically: true, encoding: .utf8)
        try "import SwiftUI\nstruct P: View { var body: some View { Text(\"p\") } }\n"
            .write(to: src.appendingPathComponent("Pods/X/P.swift"), atomically: true, encoding: .utf8)
        let options = Mirror.Options(source: src, dest: dst, manifest: root.appendingPathComponent("m.json"), jobs: 4, plain: [])

        let first = try Mirror(options: options).run()
        XCTAssertEqual(first.files, 2)
        XCTAssertEqual(first.tagged, 1)
        XCTAssertEqual(first.copied, 1, "vendor code is copied, not tagged")
        let tagged = dst.appendingPathComponent("A/V.swift")
        XCTAssertTrue(try String(contentsOf: tagged, encoding: .utf8).contains("__MyGitSourceKey"))
        let mtime = try fm.attributesOfItem(atPath: tagged.path)[.modificationDate] as! Date

        let second = try Mirror(options: options).run()
        XCTAssertEqual(second.unchanged, 2)
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(try fm.attributesOfItem(atPath: tagged.path)[.modificationDate] as! Date, mtime)

        // Forcing a file plain (after a build error) mirrors it untagged.
        var plainOptions = options
        plainOptions.plain = ["A/V.swift"]
        _ = try Mirror(options: plainOptions).run()
        XCTAssertFalse(try String(contentsOf: tagged, encoding: .utf8).contains("__MyGitSourceKey"))

        try fm.removeItem(at: src.appendingPathComponent("Pods/X/P.swift"))
        let third = try Mirror(options: options).run()
        XCTAssertEqual(third.removed, 1)
        try? fm.removeItem(at: root)
    }

    // MARK: - Branch probes

    func testMultiReturnGetterIsProbedWithoutMovingTheExpression() {
        let src = """
        import SwiftUI
        struct Model {
            var message: String? {
                if limit > 0 {
                    return "\\(count)/\\(limit)"
                }
                if flag { return nil }
                return value.isEmpty ? nil : value
            }
            var single: Int {
                return 4
            }
        }
        """
        let r = tag(src)
        let out = r.output.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(out[4]), #"       return __mB("\(count)/\(limit)")"#)
        XCTAssertEqual(String(out[7]), "   return __mB(value.isEmpty ? nil : value)")
        // Returned expressions keep their column (the index is looked up there).
        XCTAssertEqual(out[7].range(of: "value.isEmpty")?.lowerBound.utf16Offset(in: out[7]),
                       lines[7].range(of: "value.isEmpty")?.lowerBound.utf16Offset(in: lines[7]))
        // `{ return nil }` has no room: wrapped where it stands. Single returns aren't probed.
        XCTAssertEqual(String(out[6]), "        if flag { return __mB(nil) }")
        XCTAssertEqual(out[10], lines[10])
        XCTAssertTrue(r.output.contains("fileprivate func __mB<T>"))
        XCTAssertTrue(r.output.contains(#"let key = "App/V.swift:\(l)""#))
        let probed = r.symbols.filter { $0.name == "message" }.map { ($0.line, $0.probed == true) }
        XCTAssertEqual(probed.map(\.0), [5, 7, 8])
        XCTAssertEqual(probed.map(\.1), [true, true, true])
    }

    func testTokenArgumentsReportWhatTheyEvaluatedTo() {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text(label)
                    .foregroundColor(tokens.labelColor(role))
                    .padding(8)
                    .frame(width: $w, alignment: .leading)
            }
        }
        enum Tokens {
            func labelColor(_ role: Role) -> Color {
                switch role {
                case .subtle: return .gray
                case .error: return .red
                }
            }
        }
        """
        let r = tag(src)
        let out = r.output.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(out.count - 1 > lines.count, true, "helpers appended")
        XCTAssertTrue(out[3].contains(#"Text(__mT(label, "App/V.swift:4:9", 2))"#), String(out[3]))
        XCTAssertTrue(out[4].contains(#".foregroundColor(__mT(tokens.labelColor(role), "App/V.swift:4:9", 1))"#), String(out[4]))
        XCTAssertEqual(out[5], lines[5], "literals aren't probed")
        XCTAssertEqual(out[6], lines[6] + #".preference(key: __MyGitSourceKey.self, value: __mS("App/V.swift:4:9"))"#,
                       "bindings and implicit members aren't probed")
        XCTAssertTrue(out[12].contains("case .subtle: return __mB(.gray)"), "`case` returns are probed in place")
        XCTAssertTrue(r.output.contains("fileprivate func __mT<T>"))
        XCTAssertTrue(r.output.contains("fileprivate func __mS("))
        let entry = r.sourceMap["App/V.swift:4:9"]
        XCTAssertEqual(entry?.args.first?.probe, 2)
        XCTAssertEqual(entry?.mods.first { $0.name == "foregroundColor" }?.args.first?.probe, 1)
        XCTAssertEqual(entry?.mods.first { $0.name == "padding" }?.args.first?.probe, nil)
    }

    func testViewBuildersAndOpaqueReturnsAreNotProbed() {
        let r = tag("""
        import SwiftUI
        struct V: View {
            @ViewBuilder func row(_ a: Bool) -> some View {
                if a {
                    return Text("a")
                }
                return Text("b")
            }
            var body: some View { Text("x") }
        }
        """)
        XCTAssertFalse(r.output.contains("__mB("))
    }

    func testFilesWithoutViewsAreProbedToo() {
        let r = SourceTagger.probe(source: """
        import Foundation
        enum Tokens {
            static func color(_ role: Int) -> String {
                switch role {
                case 0:
                    return "red"
                default:
                    return "blue"
                }
            }
        }
        """, path: "T.swift")
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.output.contains(#"       return __mB("red")"#))
        XCTAssertNil(SourceTagger.probe(source: "struct A { var x: Int { return 1 } }", path: "A.swift"))
    }
}

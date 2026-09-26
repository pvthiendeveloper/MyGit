import Foundation
import SourceTaggerCore

// mygit-source-tagger --source <repo> --dest <mirror> [--manifest <file>]
//                     [--jobs N] [--plain <repo-relative path>]...
// mygit-source-tagger --print <file.swift> [--path <recorded path>]

let usage = """
usage: mygit-source-tagger --source DIR --dest DIR [--manifest FILE] [--map DIR] [--jobs N] [--plain REL]...
                           [--unprobed REL]...
                           [--strip-modifier NAME]...
       mygit-source-tagger --print FILE [--path REL]
"""

var args = Array(CommandLine.arguments.dropFirst())
var source: String?, dest: String?, manifest: String?, printFile: String?, recordedPath: String?, mapDir: String?
var jobs = ProcessInfo.processInfo.activeProcessorCount
var plain = Set<String>()
var unprobed = Set<String>()
var strip = Set<String>()

func value(_ flag: String) -> String {
    guard !args.isEmpty else {
        FileHandle.standardError.write(Data("missing value for \(flag)\n\(usage)\n".utf8))
        exit(2)
    }
    return args.removeFirst()
}

while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--source": source = value(flag)
    case "--dest": dest = value(flag)
    case "--manifest": manifest = value(flag)
    case "--jobs": jobs = max(1, Int(value(flag)) ?? jobs)
    case "--plain": plain.insert(value(flag))
    case "--unprobed": unprobed.insert(value(flag))
    case "--map": mapDir = value(flag)
    case "--strip-modifier": strip.insert(value(flag))
    case "--print": printFile = value(flag)
    case "--path": recordedPath = value(flag)
    case "-h", "--help": print(usage); exit(0)
    default:
        FileHandle.standardError.write(Data("unknown option \(flag)\n\(usage)\n".utf8))
        exit(2)
    }
}

if let printFile {
    guard let text = try? String(contentsOfFile: printFile, encoding: .utf8) else {
        FileHandle.standardError.write(Data("can't read \(printFile)\n".utf8))
        exit(1)
    }
    let result = SourceTagger.tag(source: text, path: recordedPath ?? printFile, stripModifiers: strip)
    print(result.output, terminator: "")
    FileHandle.standardError.write(Data("\(result.tagCount) tags\n".utf8))
    exit(0)
}

guard let source, let dest else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
}
let destURL = URL(fileURLWithPath: dest)
let options = Mirror.Options(
    source: URL(fileURLWithPath: source),
    dest: destURL,
    manifest: manifest.map(URL.init(fileURLWithPath:)) ?? destURL.deletingLastPathComponent().appendingPathComponent("tagger-manifest.json"),
    jobs: jobs,
    plain: plain,
    mapDirectory: mapDir.map(URL.init(fileURLWithPath:))
)
var mirrorOptions = options
mirrorOptions.stripModifiers = strip
mirrorOptions.unprobed = unprobed
do {
    let stats = try Mirror(options: mirrorOptions).run()
    print("▶ source tags: \(stats)")
} catch {
    FileHandle.standardError.write(Data("tagging failed: \(error)\n".utf8))
    exit(1)
}

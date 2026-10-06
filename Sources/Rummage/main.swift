import AppKit

let args = CommandLine.arguments

// Debug: Rummage --cli <folder> "<query>"
if args.count >= 3 && args[1] == "--cli" {
    let root = FileIndex.canonical(URL(fileURLWithPath: args[2]))
    let query = args.count > 3 ? args[3] : ""
    let t0 = CFAbsoluteTimeGetCurrent()
    let index = FileIndex(root: root, showHidden: false, skipHeavy: true)
    index.buildSync { _ in }
    let t1 = CFAbsoluteTimeGetCurrent()
    let r = NameSearch.run(query: query, entries: index.snapshot(), root: root, token: CancelToken(), limit: 20)
    let t2 = CFAbsoluteTimeGetCurrent()
    print(String(format: "indexed %d in %.0f ms, search %.1f ms, %d matches", index.count, (t1 - t0) * 1000, (t2 - t1) * 1000, r.total))
    for h in r.hits { print((h.parent.isEmpty ? "" : h.parent + "/") + h.name, h.marks.sorted()) }
    exit(0)
}

// Debug: Rummage --watch-test <empty scratch folder>  (live-update self test)
if args.count >= 3 && args[1] == "--watch-test" {
    let fm = FileManager.default
    let root = FileIndex.canonical(URL(fileURLWithPath: args[2]))
    func p(_ rel: String) -> URL { root.appendingPathComponent(rel) }
    func touch(_ rel: String) { fm.createFile(atPath: p(rel).path, contents: Data("hi".utf8)) }
    try? fm.createDirectory(at: p("sub"), withIntermediateDirectories: true)
    touch("a.txt"); touch("sub/b.txt"); touch(".hidden.txt")

    let index = FileIndex(root: root, showHidden: false, skipHeavy: true)
    index.buildSync { _ in }
    let watcher = FolderWatcher(root: root.path) { changes, _ in _ = index.apply(changes) }
    func rels() -> Set<String> { Set(index.snapshot().map(\.rel)) }
    var failed = 0
    func expect(_ name: String, _ ok: (Set<String>) -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { if ok(rels()) { print("PASS", name); return }; usleep(50_000) }
        failed += 1
        print("FAIL", name, rels().sorted())
    }
    usleep(300_000)
    expect("initial") { $0 == ["a.txt", "sub", "sub/b.txt"] }
    touch("c.txt")
    expect("create file") { $0.contains("c.txt") }
    try? fm.moveItem(at: p("sub"), to: p("sub2"))
    expect("rename folder") { $0.contains("sub2/b.txt") && !$0.contains("sub/b.txt") && !$0.contains("sub") }
    try? fm.removeItem(at: p("a.txt"))
    expect("delete file") { !$0.contains("a.txt") }
    let outside = root.deletingLastPathComponent().appendingPathComponent("ff-outside-\(getpid())")
    try? fm.createDirectory(at: outside.appendingPathComponent("deep"), withIntermediateDirectories: true)
    fm.createFile(atPath: outside.appendingPathComponent("deep/x.txt").path, contents: nil)
    try? fm.moveItem(at: outside, to: p("moved-in"))
    expect("move folder in") { $0.contains("moved-in/deep/x.txt") }
    try? fm.createDirectory(at: p("node_modules/pkg"), withIntermediateDirectories: true)
    touch("node_modules/pkg/index.js"); touch(".hidden2.txt")
    usleep(1_200_000)
    expect("skip node_modules + hidden") { !$0.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".") } }
    try? fm.removeItem(at: p("sub2"))
    expect("delete folder") { !$0.contains { $0.hasPrefix("sub2") } }
    watcher.stop()
    print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

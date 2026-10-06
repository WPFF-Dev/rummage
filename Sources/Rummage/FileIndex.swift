import Foundation

struct Entry {
    let rel: String          // path relative to the index root
    let frel: [UInt16]       // folded (case/diacritics-insensitive) rel path, UTF-16
    let nameStart: Int32     // where the file name starts inside frel
    let depth: Int16
    let isDir: Bool
    let isPackage: Bool
    let size: Int64
    let date: Double
}

/// In-memory recursive listing of one folder.
final class FileIndex {
    static let heavyDirs: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "__pycache__", ".next", ".nuxt",
        ".cache", "DerivedData", ".build", ".Trash", ".venv",
    ]
    static let maxEntries = 400_000

    let root: URL
    let showHidden: Bool
    let skipHeavy: Bool

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var _finished = false
    private var _cancelled = false
    private(set) var builtAt = Date()
    private(set) var truncated = false

    /// Canonical path (`/private/tmp`, not `/tmp`), the form the enumerator and FSEvents report.
    static func canonical(_ url: URL) -> URL {
        guard let real = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    init(root: URL, showHidden: Bool, skipHeavy: Bool) {
        self.root = FileIndex.canonical(root)
        self.showHidden = showHidden
        self.skipHeavy = skipHeavy
    }

    func snapshot() -> [Entry] { lock.withLock { entries } }
    var count: Int { lock.withLock { entries.count } }
    var finished: Bool { lock.withLock { _finished } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
    private static let keySet = Set(keys)

    private var prefix: String {
        let p = root.path
        return p.hasSuffix("/") ? p : p + "/"
    }

    private func makeEntry(rel: String, rv: URLResourceValues?) -> Entry {
        let frel = Matcher.fold(rel)
        var nameStart = 0
        var depth = 0
        for (i, c) in frel.enumerated() where c == 47 { nameStart = i + 1; depth += 1 }
        return Entry(rel: rel, frel: frel, nameStart: Int32(nameStart), depth: Int16(min(depth, 999)),
                     isDir: rv?.isDirectory ?? false, isPackage: rv?.isPackage ?? false,
                     size: Int64(rv?.fileSize ?? 0),
                     date: rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// Lists everything below `start` (not `start` itself). `visit` returns false to stop.
    private func walk(_ start: URL, _ visit: (Entry) -> Bool) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let prefix = self.prefix
        guard let en = FileManager.default.enumerator(at: start, includingPropertiesForKeys: FileIndex.keys,
                                                      options: options, errorHandler: { _, _ in true }) else { return }
        var done = false
        while !done {
            autoreleasepool {
                for _ in 0..<512 {
                    guard let url = en.nextObject() as? URL else { done = true; break }
                    let rv = try? url.resourceValues(forKeys: FileIndex.keySet)
                    if (rv?.isDirectory ?? false) && skipHeavy && FileIndex.heavyDirs.contains(url.lastPathComponent) {
                        en.skipDescendants()
                        continue
                    }
                    let path = url.path
                    let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
                    if !visit(makeEntry(rel: rel, rv: rv)) { done = true; break }
                }
            }
        }
    }

    /// Walks the tree on the calling thread; `onBatch` gets the running count.
    func buildSync(onBatch: (Int) -> Void) {
        var batch: [Entry] = []
        batch.reserveCapacity(4096)
        var total = 0
        var lastFlush = CFAbsoluteTimeGetCurrent()

        func flush() {
            guard !batch.isEmpty else { return }
            lock.withLock { entries.append(contentsOf: batch) }
            batch.removeAll(keepingCapacity: true)
            lastFlush = CFAbsoluteTimeGetCurrent()
            onBatch(total)
        }

        walk(root) { entry in
            batch.append(entry)
            total += 1
            if total & 511 == 0 {
                if cancelled { return false }
                if total >= FileIndex.maxEntries { truncated = true; return false }
                if batch.count >= 4000 || CFAbsoluteTimeGetCurrent() - lastFlush > 0.15 { flush() }
            }
            return true
        }
        flush()
        builtAt = Date()
        lock.withLock { _finished = true }
    }

    /// Applies FSEvents changes in place. Returns true when the listing changed.
    func apply(_ changes: [FSChange]) -> Bool {
        let prefix = self.prefix
        var touched: [String: Bool] = [:] // rel -> structural
        for c in changes {
            var path = c.path
            if path.hasSuffix("/") { path.removeLast() }
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            guard !rel.isEmpty, !isExcluded(rel) else { continue }
            touched[rel] = (touched[rel] ?? false) || c.structural
        }
        guard !touched.isEmpty else { return false }

        var replace = Set<String>()       // entries to drop and re-add
        var dropBelow: [String] = []      // "rel/" prefixes whose contents are re-listed or gone
        var added: [Entry] = []
        for (rel, structural) in touched {
            replace.insert(rel)
            let url = root.appendingPathComponent(rel)
            guard let rv = try? url.resourceValues(forKeys: FileIndex.keySet) else {
                dropBelow.append(rel + "/") // removed
                continue
            }
            let entry = makeEntry(rel: rel, rv: rv)
            added.append(entry)
            if structural && entry.isDir && !entry.isPackage {
                dropBelow.append(rel + "/")
                walk(url) { added.append($0); return added.count < 100_000 }
            }
        }

        lock.withLock {
            entries.removeAll { e in
                replace.contains(e.rel) || (!dropBelow.isEmpty && dropBelow.contains { e.rel.hasPrefix($0) })
            }
            entries.append(contentsOf: added)
        }
        return true
    }

    /// Paths the full scan would not list: hidden, inside skipped folders or inside packages.
    private func isExcluded(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/")
        if !showHidden && parts.contains(where: { $0.hasPrefix(".") }) { return true }
        if skipHeavy && parts.dropLast().contains(where: { FileIndex.heavyDirs.contains(String($0)) }) { return true }
        if skipHeavy, let last = parts.last, FileIndex.heavyDirs.contains(String(last)) { return true }
        var url = root
        for part in parts.dropLast() {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        }
        return false
    }
}

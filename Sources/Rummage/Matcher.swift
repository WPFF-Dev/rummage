import Foundation

typealias Chars = UnsafeBufferPointer<UInt16>

enum Matcher {
    static func fold(_ s: String) -> [UInt16] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf16)
    }

    static func find(_ needle: [UInt16], in hay: Chars, from start: Int = 0) -> Int? {
        let n = needle.count, h = hay.count
        if n == 0 { return 0 }
        if n > h - start { return nil }
        let first = needle[0]
        var i = start
        while i <= h - n {
            if hay[i] == first {
                var j = 1
                while j < n && hay[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    static func isBoundary(_ s: Chars, _ i: Int) -> Bool {
        if i == 0 { return true }
        switch s[i - 1] {
        case 32, 95, 45, 46, 47, 40, 41, 91, 93, 44, 43, 38: return true // space _ - . / ( ) [ ] , + &
        default:
            let a = s[i - 1], b = s[i]
            let aDigit = a >= 48 && a <= 57, bDigit = b >= 48 && b <= 57
            return aDigit != bDigit
        }
    }

    /// Score of one query token against a file name; 0 = no match.
    static func scoreName(_ t: [UInt16], _ name: Chars) -> Int {
        if let idx = find(t, in: name) {
            var s = 1000
            if t.count == name.count {
                s += 3000
            } else if idx == 0 {
                s += 1200
            } else if isBoundary(name, idx) {
                s += 600
            } else {
                var k = idx + 1
                while let j = find(t, in: name, from: k) {
                    if isBoundary(name, j) { s += 500; break }
                    k = j + 1
                }
            }
            return s - min(idx, 60) * 3
        }
        // Fuzzy: all token chars in order.
        guard t.count >= 3 else { return 0 }
        var ti = 0, last = -1, gaps = 0, bonus = 0, firstIdx = -1, i = 0
        while i < name.count && ti < t.count {
            if name[i] == t[ti] {
                if firstIdx < 0 { firstIdx = i }
                if last >= 0 && i != last + 1 { gaps += i - last - 1 }
                if isBoundary(name, i) { bonus += 40 }
                last = i
                ti += 1
            }
            i += 1
        }
        guard ti == t.count else { return 0 }
        return max(1, 350 + bonus - gaps * 10 - firstIdx * 3)
    }

    /// Character positions to highlight in the folded name.
    static func positions(_ tokens: [[UInt16]], _ name: Chars) -> Set<Int> {
        var out = Set<Int>()
        for t in tokens where !t.isEmpty {
            if let idx = find(t, in: name) {
                var best = idx
                var k = idx + 1
                if !isBoundary(name, idx) {
                    while let j = find(t, in: name, from: k) {
                        if isBoundary(name, j) { best = j; break }
                        k = j + 1
                    }
                }
                for p in best..<(best + t.count) { out.insert(p) }
            } else {
                var ti = 0, i = 0
                var found: [Int] = []
                while i < name.count && ti < t.count {
                    if name[i] == t[ti] { found.append(i); ti += 1 }
                    i += 1
                }
                if ti == t.count { out.formUnion(found) }
            }
        }
        return out
    }
}

final class CancelToken {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
}

struct ParsedQuery {
    enum Kind { case dir, file }
    struct Token { let chars: [UInt16]; let pathOnly: Bool }

    var tokens: [Token] = []
    var exts: [[UInt16]] = []
    var kind: Kind?

    init(_ s: String) {
        for part in s.split(whereSeparator: { $0 == " " }) {
            let p = String(part)
            let low = p.lowercased()
            if low.hasPrefix("ext:") {
                exts += low.dropFirst(4).split(separator: ",").map {
                    Array(String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".*")).utf16)
                }.filter { !$0.isEmpty }
                continue
            }
            if low.hasPrefix("*.") && low.count > 2 {
                exts.append(Array(String(low.dropFirst(2)).utf16))
                continue
            }
            if low == "kind:dir" || low == "kind:folder" || low == "тип:папка" { kind = .dir; continue }
            if low == "kind:file" || low == "тип:файл" { kind = .file; continue }
            tokens.append(Token(chars: Matcher.fold(p), pathOnly: p.contains("/")))
        }
    }

    var isEmpty: Bool { tokens.isEmpty }
}

struct Hit: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let parent: String
    let isDir: Bool
    let isPackage: Bool
    let size: Int64
    let date: Double
    var marks: Set<Int> = []
    var snippet: String? = nil
    var line: Int? = nil
}

enum NameSearch {
    static func score(_ e: Entry, _ q: ParsedQuery) -> Int? {
        if let k = q.kind, (k == .dir) != e.isDir { return nil }
        return e.frel.withUnsafeBufferPointer { rel -> Int? in
            let name = Chars(rebasing: rel[Int(e.nameStart)...])
            if !q.exts.isEmpty {
                guard !e.isDir || e.isPackage,
                      let dot = name.lastIndex(of: 46) else { return nil }
                let ext = Array(name[(dot + 1)...])
                if !q.exts.contains(ext) { return nil }
            }
            var total = 0
            for t in q.tokens {
                var s = t.pathOnly ? 0 : Matcher.scoreName(t.chars, name)
                if s == 0 {
                    guard Matcher.find(t.chars, in: rel) != nil else { return nil }
                    s = 120
                }
                total += s
            }
            total -= Int(e.depth) * 15 + name.count
            if e.isDir { total += 25 }
            return total
        }
    }

    static func makeHit(_ e: Entry, root: URL, tokens: [[UInt16]]) -> Hit {
        let name = (e.rel as NSString).lastPathComponent
        var marks = Set<Int>()
        if !tokens.isEmpty {
            e.frel.withUnsafeBufferPointer { rel in
                let fname = Chars(rebasing: rel[Int(e.nameStart)...])
                if fname.count == name.utf16.count { marks = Matcher.positions(tokens, fname) }
            }
        }
        return Hit(url: root.appendingPathComponent(e.rel), name: name,
                   parent: (e.rel as NSString).deletingLastPathComponent,
                   isDir: e.isDir, isPackage: e.isPackage, size: e.size, date: e.date, marks: marks)
    }

    static func run(query: String, entries: [Entry], root: URL, token: CancelToken, limit: Int) -> (hits: [Hit], total: Int) {
        let q = ParsedQuery(query)
        let n = entries.count

        if q.isEmpty {
            // No text: most recently modified files (respecting ext:/kind: filters).
            var idx: [Int] = []
            for i in 0..<n {
                let e = entries[i]
                if q.kind == nil && e.isDir && !e.isPackage { continue }
                if score(e, q) != nil { idx.append(i) }
            }
            let total = idx.count
            idx.sort { entries[$0].date > entries[$1].date }
            return (idx.prefix(limit).map { makeHit(entries[$0], root: root, tokens: []) }, total)
        }

        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 4000))
        var partial = [[(Int, Int)]](repeating: [], count: chunks)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var local: [(Int, Int)] = []
            let lo = n * c / chunks, hi = n * (c + 1) / chunks
            var i = lo
            while i < hi {
                if i & 2047 == 0 && token.cancelled { break }
                if let s = score(entries[i], q) { local.append((s, i)) }
                i += 1
            }
            lock.withLock { partial[c] = local }
        }
        var all = partial.flatMap { $0 }
        let total = all.count
        all.sort { a, b in
            a.0 != b.0 ? a.0 > b.0 : entries[a.1].rel.count < entries[b.1].rel.count
        }
        let toks = q.tokens.filter { !$0.pathOnly }.map(\.chars)
        return (all.prefix(limit).map { makeHit(entries[$0.1], root: root, tokens: toks) }, total)
    }
}

import Foundation

/// Text-inside-files search: grep (text/code, with a line snippet) + Spotlight `mdfind -onlyin` (PDF, DOCX…).
final class ContentSearch {
    static let limit = 500

    private var procs: [Process] = []
    private let queue = DispatchQueue(label: "content-search")

    func cancel() {
        for p in procs where p.isRunning { p.terminate() }
        procs.removeAll()
    }

    func run(query: String, root: URL, showHidden: Bool, skipHeavy: Bool,
             onHits: @escaping ([Hit]) -> Void, onDone: @escaping () -> Void) {
        cancel()
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var pending = 2
        let finishOne = { DispatchQueue.main.async { pending -= 1; if pending == 0 { onDone() } } }

        // grep
        var args = ["-rIin", "--null", "-m", "1", "-F"]
        if skipHeavy { args += FileIndex.heavyDirs.map { "--exclude-dir=\($0)" } }
        if !showHidden { args += ["--exclude-dir=.*", "--exclude=.*"] }
        args += ["-e", query, rootPath]
        let grep = makeProcess("/usr/bin/grep", args)
        var buffer = Data()
        var count = 0
        var stopped = false
        let out = grep.standardOutput as! Pipe
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            self?.queue.async {
                guard !stopped else { return }
                if chunk.isEmpty { return }
                buffer.append(chunk)
                var hits: [Hit] = []
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let hit = Self.parseGrep(line, prefix: prefix) { hits.append(hit) }
                }
                count += hits.count
                if !hits.isEmpty { DispatchQueue.main.async { onHits(hits) } }
                if count >= ContentSearch.limit {
                    stopped = true
                    if grep.isRunning { grep.terminate() }
                }
            }
        }
        grep.terminationHandler = { _ in
            out.fileHandleForReading.readabilityHandler = nil
            finishOne()
        }

        // Spotlight
        let md = makeProcess("/usr/bin/mdfind", ["-onlyin", rootPath, query])
        let mdOut = md.standardOutput as! Pipe
        var mdData = Data()
        mdOut.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if !chunk.isEmpty { mdData.append(chunk) }
        }
        md.terminationHandler = { _ in
            mdOut.fileHandleForReading.readabilityHandler = nil
            mdData.append(mdOut.fileHandleForReading.readDataToEndOfFile())
            let text = String(decoding: mdData, as: UTF8.self)
            var hits: [Hit] = []
            for path in text.split(separator: "\n").prefix(ContentSearch.limit) {
                let p = String(path)
                if !showHidden && p.dropFirst(prefix.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if let h = Self.makeHit(path: p, prefix: prefix, snippet: nil, line: nil) { hits.append(h) }
            }
            if !hits.isEmpty { DispatchQueue.main.async { onHits(hits) } }
            finishOne()
        }

        for p in [grep, md] {
            do {
                try p.run()
                procs.append(p)
            } catch {
                finishOne()
            }
        }
    }

    private func makeProcess(_ exe: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        return p
    }

    /// grep --null line: "<path>\0<lineNo>:<text>"
    private static func parseGrep(_ line: Data, prefix: String) -> Hit? {
        guard let z = line.firstIndex(of: 0) else { return nil }
        let path = String(decoding: line[line.startIndex..<z], as: UTF8.self)
        let rest = String(decoding: line[line.index(after: z)...], as: UTF8.self)
        var lineNo: Int?
        var text = rest
        if let colon = rest.firstIndex(of: ":") {
            lineNo = Int(rest[rest.startIndex..<colon])
            text = String(rest[rest.index(after: colon)...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 240 { text = String(text.prefix(240)) + "…" }
        return makeHit(path: path, prefix: prefix, snippet: text, line: lineNo)
    }

    private static func makeHit(path: String, prefix: String, snippet: String?, line: Int?) -> Hit? {
        let url = URL(fileURLWithPath: path)
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
        let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        return Hit(url: url, name: url.lastPathComponent,
                   parent: (rel as NSString).deletingLastPathComponent,
                   isDir: rv?.isDirectory ?? false, isPackage: rv?.isPackage ?? false,
                   size: Int64(rv?.fileSize ?? 0),
                   date: rv?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                   snippet: snippet, line: line)
    }
}

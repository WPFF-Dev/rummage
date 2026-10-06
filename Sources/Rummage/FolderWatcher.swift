import CoreServices
import Foundation

struct FSChange {
    let path: String
    let structural: Bool // created / removed / renamed: a folder's contents must be re-listed
}

/// Watches a folder tree with FSEvents (per-file events).
final class FolderWatcher {
    let root: String
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "folder-watcher")
    private let onChange: ([FSChange], _ rescan: Bool) -> Void

    init(root: String, onChange: @escaping ([FSChange], Bool) -> Void) {
        self.root = root
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let rescanMask = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            let structuralMask = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
            var rescan = false
            var changes: [FSChange] = []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                if f & rescanMask != 0 { rescan = true }
                changes.append(FSChange(path: list[i], structural: f & structuralMask != 0))
            }
            me.onChange(changes, rescan)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Keep self alive until a callback that may already be running has finished.
        queue.async { [self] in _ = self }
    }
}

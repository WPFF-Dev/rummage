import AppKit

/// Talks to Finder over Apple Events (asks for Automation permission once).
enum FinderBridge {
    /// Folder shown in the front Finder window, or the Desktop when there is none.
    static func currentFolder() -> URL? {
        let src = """
        tell application "Finder"
            try
                if (count of Finder windows) > 0 then
                    return POSIX path of (target of front Finder window as alias)
                end if
            end try
            return POSIX path of (desktop as alias)
        end tell
        """
        guard let path = run(src)?.stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Shows the item selected in the front Finder window (navigates the window to its folder).
    static func reveal(_ url: URL) {
        let src = """
        tell application "Finder"
            set f to (POSIX file "\(escape(url.path))") as alias
            if (count of Finder windows) > 0 then
                set target of front Finder window to (container of f)
            else
                make new Finder window to (container of f)
            end if
            select f
            activate
        end tell
        """
        if run(src) == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Opens a folder in the front Finder window.
    static func navigate(to url: URL) {
        let src = """
        tell application "Finder"
            set f to (POSIX file "\(escape(url.path))") as alias
            if (count of Finder windows) > 0 then
                set target of front Finder window to f
            else
                make new Finder window to f
            end if
            activate
        end tell
        """
        if run(src) == nil { NSWorkspace.shared.open(url) }
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Rummage AppleScript error: \(error)") ; return nil }
        return result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

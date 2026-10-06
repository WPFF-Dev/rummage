import AppKit

enum Language: String, CaseIterable {
    case en, ru
    var title: String { self == .en ? "English" : "Русский" }

    /// macOS language (honours a per-app language set in System Settings); anything but Russian → English.
    static var system: Language {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }
}

/// What the user picked in the menu.
enum LanguageChoice: String, CaseIterable {
    case system, en, ru

    var language: Language {
        switch self {
        case .system: return Language.system
        case .en: return .en
        case .ru: return .ru
        }
    }

    var title: String {
        switch self {
        case .system: return L("Same as macOS", "Как в системе") + " (\(Language.system.title))"
        case .en: return Language.en.title
        case .ru: return Language.ru.title
        }
    }
}

/// Inline translation: L("Open", "Открыть").
func L(_ en: String, _ ru: String) -> String {
    Settings.shared.language == .ru ? ru : en
}

/// Code editors that open `<scheme>://file/<path>:<line>` URLs.
struct Editor {
    let name: String
    let bundleID: String
    let scheme: String

    static let all: [Editor] = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", scheme: "vscode"),
        Editor(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", scheme: "vscode-insiders"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", scheme: "cursor"),
        Editor(name: "Antigravity", bundleID: "com.google.antigravity", scheme: "antigravity"),
        Editor(name: "Antigravity IDE", bundleID: "com.google.antigravity-ide", scheme: "antigravity-ide"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf", scheme: "windsurf"),
    ]

    static var installed: [Editor] { all.filter { $0.appURL != nil } }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Opens a file (at a line when given) or a folder in the editor.
    func open(_ url: URL, line: Int?, isDir: Bool) {
        if !isDir, let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let link = URL(string: "\(scheme)://file\(encoded):\(line ?? 1)"),
           NSWorkspace.shared.open(link) {
            return
        }
        guard let app = appURL else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

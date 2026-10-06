import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let model = SearchModel()
    private let hotKey = HotKey()
    private var panel: SearchPanel!
    private var statusItem: NSStatusItem!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SearchPanel(model: model)
        model.onClose = { [weak self] in self?.panel.hide() }
        model.onModal = { [weak self] on in self?.panel.keepOpen = on }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Rummage")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        HotKey.action = { [weak self] in self?.toggle() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateHotKey(frontmost: NSWorkspace.shared.frontmostApplication)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) ?? e
        }
    }

    // MARK: Hotkey

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateHotKey(frontmost: app)
    }

    /// In "Finder only" mode the shortcut exists only while Finder is in front,
    /// so it never steals the same keys from other apps.
    private func updateHotKey(frontmost: NSRunningApplication?) {
        let isFinder = frontmost?.bundleIdentifier == "com.apple.finder"
        if !settings.finderOnly || isFinder || panel.isVisible {
            hotKey.register(settings.hotKey)
        } else {
            hotKey.unregister()
        }
    }

    @objc func toggle() {
        if panel.isVisible { panel.hide(); return }
        let folder = FinderBridge.currentFolder() ?? model.root
        model.open(root: folder)
        panel.show()
    }

    // MARK: Keys inside the panel

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return e }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), shift = flags.contains(.shift), opt = flags.contains(.option)
        switch e.keyCode {
        case 53: panel.hide()                                        // esc
        case 125: cmd ? model.activateSelected() : model.move(1)     // ↓ / ⌘↓
        case 126: cmd ? model.goParent() : model.move(-1)            // ↑ / ⌘↑
        case 121: model.move(10)                                     // page down
        case 116: model.move(-10)                                    // page up
        case 36, 76:                                                 // return
            if cmd { model.revealSelected() }
            else if opt { model.openInEditor() }
            else { model.activateSelected() }
        case 48: model.toggleMode()                                  // tab
        case 16 where cmd: panel.togglePreview()                     // ⌘Y
        case 8 where cmd && shift: model.copyPath()                  // ⇧⌘C
        case 17 where cmd && shift: model.openInTerminal()           // ⇧⌘T
        case 124 where cmd: model.searchInsideSelectedFolder()        // ⌘→: search inside folder
        case 13 where cmd: panel.hide()                              // ⌘W
        default: return e
        }
        return nil
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: L("Search in Finder Folder", "Искать в папке Finder") + "   \(settings.hotKey.title)",
                              action: #selector(toggle), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        addSubmenu(menu, L("Shortcut", "Сочетание клавиш"),
                   HotKeyPreset.all.enumerated().map { i, p in
                       (p.modifiers == UInt32(cmdKey) ? p.title + L(" (replaces Finder search)", " (вместо поиска Finder)") : p.title,
                        i == settings.hotKeyIndex)
                   }, #selector(pickHotKey(_:)))

        let editors = Editor.installed
        if editors.isEmpty {
            let none = NSMenuItem(title: L("Code Editor: not found", "Редактор кода: не найден"), action: nil, keyEquivalent: "")
            menu.addItem(none)
        } else {
            let current = settings.editor?.bundleID
            addSubmenu(menu, L("Code Editor", "Редактор кода"),
                       editors.map { ($0.name, $0.bundleID == current) }, #selector(pickEditor(_:)))
        }
        addSubmenu(menu, L("Language", "Язык"),
                   LanguageChoice.allCases.map { ($0.title, $0 == settings.languageChoice) }, #selector(pickLanguage(_:)))

        addToggle(menu, L("Shortcut Works Only in Finder", "Сочетание работает только в Finder"), settings.finderOnly, #selector(toggleFinderOnly))
        addToggle(menu, L("Show Hidden Files", "Показывать скрытые файлы"), settings.showHidden, #selector(toggleHidden))
        addToggle(menu, L("Skip node_modules, .git, etc.", "Пропускать node_modules, .git и т.п."), settings.skipHeavy, #selector(toggleHeavy))
        addToggle(menu, L("Launch at Login", "Запускать при входе в систему"), SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Rummage", "Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ items: [(String, Bool)], _ action: Selector) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, (name, on)) in items.enumerated() {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = on ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    @objc private func pickEditor(_ sender: NSMenuItem) {
        let editors = Editor.installed
        if editors.indices.contains(sender.tag) { settings.editor = editors[sender.tag] }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        settings.languageChoice = LanguageChoice.allCases[sender.tag]
        model.objectWillChange.send()
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    @objc private func pickHotKey(_ sender: NSMenuItem) {
        settings.hotKeyIndex = sender.tag
        hotKey.unregister()
        updateHotKey(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func toggleFinderOnly() {
        settings.finderOnly.toggle()
        updateHotKey(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func toggleHidden() { settings.showHidden.toggle(); model.reindex() }
    @objc private func toggleHeavy() { settings.skipHeavy.toggle(); model.reindex() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn't change Launch at Login", "Не удалось изменить автозапуск")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

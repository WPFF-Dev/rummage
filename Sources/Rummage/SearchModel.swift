import AppKit
import SwiftUI

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: ["hotKeyIndex": 0, "finderOnly": true, "showHidden": false, "skipHeavy": true,
                              "uiLanguage": LanguageChoice.system.rawValue])
    }

    var languageChoice: LanguageChoice {
        get { LanguageChoice(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "uiLanguage") }
    }
    /// The language the UI is shown in.
    var language: Language { languageChoice.language }
    /// Chosen editor, else the first installed one.
    var editor: Editor? {
        get {
            let installed = Editor.installed
            return installed.first { $0.bundleID == d.string(forKey: "editor") } ?? installed.first
        }
        set { d.set(newValue?.bundleID, forKey: "editor") }
    }

    var hotKeyIndex: Int {
        get { min(max(d.integer(forKey: "hotKeyIndex"), 0), HotKeyPreset.all.count - 1) }
        set { d.set(newValue, forKey: "hotKeyIndex") }
    }
    var hotKey: HotKeyPreset { HotKeyPreset.all[hotKeyIndex] }
    var finderOnly: Bool { get { d.bool(forKey: "finderOnly") } set { d.set(newValue, forKey: "finderOnly") } }
    var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden") } }
    var skipHeavy: Bool { get { d.bool(forKey: "skipHeavy") } set { d.set(newValue, forKey: "skipHeavy") } }
}

enum SearchMode: String { case names, content }

final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var mode: SearchMode = .names { didSet { if mode != oldValue { scheduleSearch(immediate: true) } } }
    @Published var selection = 0
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var totalMatches = 0
    @Published private(set) var root = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var indexedCount = 0
    @Published private(set) var indexing = false
    @Published private(set) var truncated = false
    @Published private(set) var searchingContent = false
    @Published private(set) var toast: String?
    @Published private(set) var focusTick = 0

    /// Set by the app: hide the panel.
    var onClose: (() -> Void)?
    /// Set by the app: keep the panel open while a modal (folder chooser) is up.
    var onModal: ((Bool) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// Set by the panel; results are refreshed on file changes only while it is shown.
    var panelVisible = false

    private let settings = Settings.shared
    private var watcher: FolderWatcher?
    private var watchedKey: String?
    private var pendingChanges: [FSChange] = []
    private var pendingRescan = false
    private var buildBacklog: [FSChange] = []
    private var changeDebounce: DispatchWorkItem?
    private var lastContentRefresh = Date.distantPast
    private let applyQueue = DispatchQueue(label: "index-apply", qos: .userInitiated)
    private var index: FileIndex?
    private var building: FileIndex?
    private var cache: [String: FileIndex] = [:]
    private var cacheOrder: [String] = []
    private let searchQueue = DispatchQueue(label: "name-search", qos: .userInitiated)
    private var token: CancelToken?
    private var debounce: DispatchWorkItem?
    private var lastProgressSearch = Date.distantPast
    private let content = ContentSearch()

    var selected: Hit? { hits.indices.contains(selection) ? hits[selection] : nil }

    var rootDisplay: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = root.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    // MARK: - Opening a folder

    func open(root newRoot: URL) {
        let r = FileIndex.canonical(newRoot)
        root = r
        query = ""
        selection = 0
        loadIndex()
        scheduleSearch(immediate: true)
        focusTick += 1
    }

    /// Settings changed (hidden files etc.): drop caches and reindex.
    func reindex() {
        cache.removeAll()
        cacheOrder.removeAll()
        loadIndex()
        scheduleSearch(immediate: true)
    }

    private var cacheKey: String { "\(root.path)|\(settings.showHidden)|\(settings.skipHeavy)" }

    private func loadIndex() {
        let key = cacheKey
        // A cached index stays exact only while this folder has been watched the whole time.
        let wasWatched = watcher != nil && watchedKey == key
        startWatching(key: key)
        if let cached = cache[key], cached.finished {
            index = cached
            indexedCount = cached.count
            truncated = cached.truncated
            indexing = false
            if !wasWatched { build(key: key, swapWhenDone: true) }
        } else {
            build(key: key, swapWhenDone: false)
        }
    }

    // MARK: - Live updates (FSEvents)

    private func startWatching(key: String) {
        guard watchedKey != key || watcher == nil else { return }
        watcher?.stop()
        pendingChanges.removeAll()
        pendingRescan = false
        buildBacklog.removeAll()
        watchedKey = key
        watcher = FolderWatcher(root: root.path) { [weak self] changes, rescan in
            DispatchQueue.main.async { self?.filesChanged(changes, rescan: rescan, key: key) }
        }
    }

    private func filesChanged(_ changes: [FSChange], rescan: Bool, key: String) {
        guard watchedKey == key else { return }
        pendingChanges += changes
        pendingRescan = pendingRescan || rescan
        changeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.processChanges(key: key) }
        changeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func processChanges(key: String) {
        guard watchedKey == key, cacheKey == key else { return }
        let changes = pendingChanges
        let rescan = pendingRescan
        pendingChanges.removeAll()
        pendingRescan = false
        if rescan || changes.count > 5000 {
            build(key: key, swapWhenDone: index?.finished ?? false)
            return
        }
        // A scan in progress may already have passed these paths: replay them when it ends.
        if building != nil { buildBacklog += changes }
        guard let idx = index, idx.finished else { return }
        applyChanges(changes, to: idx)
    }

    private func applyChanges(_ changes: [FSChange], to idx: FileIndex) {
        applyQueue.async { [weak self] in
            guard idx.apply(changes) else { return }
            DispatchQueue.main.async {
                guard let self, self.index === idx else { return }
                self.indexedCount = idx.count
                self.refreshAfterChange()
            }
        }
    }

    private func refreshAfterChange() {
        guard panelVisible else { return }
        switch mode {
        case .names:
            runSearch(keepSelection: true)
        case .content:
            // grep is heavier: at most every 2 s, and keep the old list until the new one is ready.
            guard Date().timeIntervalSince(lastContentRefresh) > 2, !searchingContent else { return }
            lastContentRefresh = Date()
            runSearch(keepSelection: true, soft: true)
        }
    }

    private func build(key: String, swapWhenDone: Bool) {
        building?.cancel()
        let idx = FileIndex(root: root, showHidden: settings.showHidden, skipHeavy: settings.skipHeavy)
        building = idx
        if !swapWhenDone {
            index = idx
            indexedCount = 0
            indexing = true
            truncated = false
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            idx.buildSync { count in
                DispatchQueue.main.async {
                    guard let self, self.index === idx else { return }
                    self.indexedCount = count
                    // Refresh results while indexing, but not on every batch.
                    if Date().timeIntervalSince(self.lastProgressSearch) > 0.3 && self.mode == .names {
                        self.lastProgressSearch = Date()
                        self.runSearch(keepSelection: true)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, !idx.cancelled else { return }
                if self.building === idx { self.building = nil }
                self.remember(key: key, idx)
                if swapWhenDone {
                    guard self.cacheKey == key else { return }
                    self.index = idx
                }
                guard self.index === idx else { return }
                self.indexing = false
                self.indexedCount = idx.count
                self.truncated = idx.truncated
                if self.mode == .names { self.runSearch(keepSelection: true) }
                if self.building == nil && !self.buildBacklog.isEmpty {
                    let backlog = self.buildBacklog
                    self.buildBacklog.removeAll()
                    self.applyChanges(backlog, to: idx)
                }
            }
        }
    }

    private func remember(key: String, _ idx: FileIndex) {
        cache[key] = idx
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 4 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    // MARK: - Searching

    func scheduleSearch(immediate: Bool = false) {
        debounce?.cancel()
        let delay = immediate ? 0 : (mode == .names ? 0.02 : 0.35)
        let work = DispatchWorkItem { [weak self] in self?.runSearch(keepSelection: false) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runSearch(keepSelection: Bool, soft: Bool = false) {
        token?.cancel()
        let t = CancelToken()
        token = t
        content.cancel()
        searchingContent = false

        switch mode {
        case .names:
            guard let index else { hits = []; return }
            let q = query, rootURL = root
            let entries = index.snapshot()
            let prevID = keepSelection ? selected?.id : nil
            searchQueue.async { [weak self] in
                let r = NameSearch.run(query: q, entries: entries, root: rootURL, token: t, limit: 300)
                DispatchQueue.main.async {
                    guard let self, !t.cancelled else { return }
                    self.hits = r.hits
                    self.totalMatches = r.total
                    self.selection = prevID.flatMap { id in r.hits.firstIndex { $0.id == id } } ?? 0
                    self.onSelectionChange?()
                }
            }

        case .content:
            let prevID = keepSelection ? selected?.id : nil
            if !soft {
                hits = []
                totalMatches = 0
                selection = 0
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { hits = []; totalMatches = 0; return }
            searchingContent = !soft
            var seen = Set<String>()
            var fresh: [Hit] = [] // soft mode: collected here, swapped in at the end
            content.run(query: q, root: root, showHidden: settings.showHidden, skipHeavy: settings.skipHeavy,
                        onHits: { [weak self] new in
                            guard let self, !t.cancelled else { return }
                            let unique = new.filter { seen.insert($0.id).inserted }
                            if soft { fresh += unique; return }
                            guard !unique.isEmpty, self.hits.count < ContentSearch.limit else { return }
                            self.hits.append(contentsOf: unique)
                            self.totalMatches = self.hits.count
                        },
                        onDone: { [weak self] in
                            guard let self, !t.cancelled else { return }
                            self.searchingContent = false
                            if soft {
                                self.hits = Array(fresh.prefix(ContentSearch.limit))
                                self.totalMatches = self.hits.count
                                self.selection = prevID.flatMap { id in self.hits.firstIndex { $0.id == id } } ?? 0
                                self.onSelectionChange?()
                            }
                        })
        }
    }

    // MARK: - Actions

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
        onSelectionChange?()
    }

    func toggleMode() { mode = (mode == .names) ? .content : .names }

    func openSelected() {
        guard let h = selected else { return }
        onClose?()
        if h.isDir && !h.isPackage {
            FinderBridge.navigate(to: h.url)
        } else {
            NSWorkspace.shared.open(h.url)
        }
    }

    func revealSelected() {
        guard let h = selected else { return }
        onClose?()
        FinderBridge.reveal(h.url)
    }

    func copyPath() {
        guard let h = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h.url.path, forType: .string)
        flash(L("Path copied", "Путь скопирован"))
    }

    /// Opens in the code editor; content matches jump to the found line.
    func openInEditor() {
        guard let h = selected else { return }
        guard let editor = settings.editor else {
            flash(L("No code editor found (VS Code, Cursor…)", "Редактор кода не найден (VS Code, Cursor…)"))
            return
        }
        onClose?()
        editor.open(h.url, line: h.line, isDir: h.isDir && !h.isPackage)
    }

    /// ↵: content matches with a line go to the editor, everything else opens normally.
    func activateSelected() {
        if let h = selected, h.line != nil, settings.editor != nil { openInEditor() } else { openSelected() }
    }

    func openInTerminal() {
        guard let h = selected else { return }
        let dir = (h.isDir && !h.isPackage) ? h.url : h.url.deletingLastPathComponent()
        onClose?()
        NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func searchInsideSelectedFolder() {
        guard let h = selected, h.isDir else { return }
        open(root: h.url)
    }

    func goParent() {
        guard root.path != "/" else { return }
        open(root: root.deletingLastPathComponent())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.prompt = L("Search Here", "Искать здесь")
        onModal?(true)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        onModal?(false)
        if response == .OK, let url = panel.url { open(root: url) } else { focusTick += 1 }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}

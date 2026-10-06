import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 360)
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.mode == .names ? "magnifyingglass" : "text.magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                TextField(model.mode == .names ? L("File or folder name…", "Имя файла или папки…")
                                               : L("Text inside files…", "Текст внутри файлов…"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                if model.indexing || model.searchingContent {
                    ProgressView().controlSize(.small)
                }
                Picker("", selection: $model.mode) {
                    Text(L("Names", "Имена")).tag(SearchMode.names)
                    Text(L("Contents", "Содержимое")).tag(SearchMode.content)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(L("Tab switches the mode", "Tab — переключить режим"))
            }
            HStack(spacing: 6) {
                Button { model.goParent() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .help(L("Parent folder (⌘↑)", "Папка выше (⌘↑)"))
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(model.rootDisplay)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Button(L("Other Folder…", "Другая папка…")) { model.chooseFolder() }
                    .buttonStyle(.borderless)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { i, hit in
                        HitRow(hit: hit, selected: i == model.selection)
                            .id(hit.id)
                            .contentShape(Rectangle())
                            .gesture(TapGesture(count: 2).onEnded {
                                model.selection = i
                                model.activateSelected()
                            })
                            .simultaneousGesture(TapGesture().onEnded { model.selection = i })
                            .onDrag { NSItemProvider(object: hit.url as NSURL) }
                            .contextMenu { contextMenu(i) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, s in
                if model.hits.indices.contains(s) { proxy.scrollTo(model.hits[s].id) }
            }
            .overlay { if model.hits.isEmpty { emptyState } }
        }
    }

    @ViewBuilder
    private func contextMenu(_ i: Int) -> some View {
        let hit = model.hits.indices.contains(i) ? model.hits[i] : nil
        Button(L("Open", "Открыть")) { model.selection = i; model.openSelected() }
        if let editor = Settings.shared.editor {
            let at = hit?.line.map { L(" at line \($0)", " на строке \($0)") } ?? ""
            Button(L("Open in \(editor.name)\(at)", "Открыть в \(editor.name)\(at)")) {
                model.selection = i; model.openInEditor()
            }
        }
        Button(L("Show in Finder", "Показать в Finder")) { model.selection = i; model.revealSelected() }
        Button(L("Copy Path", "Копировать путь")) { model.selection = i; model.copyPath() }
        Button(L("Open in Terminal", "Открыть в Терминале")) { model.selection = i; model.openInTerminal() }
        if hit?.isDir == true {
            Button(L("Search Inside This Folder", "Искать внутри этой папки")) {
                model.selection = i; model.searchInsideSelectedFolder()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(emptyText).foregroundStyle(.secondary)
        }
    }

    private var emptyText: String {
        if model.mode == .content {
            if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                return L("Type at least 2 characters", "Введите минимум 2 символа")
            }
            return model.searchingContent ? L("Searching…", "Ищу…") : L("Nothing found", "Ничего не найдено")
        }
        if model.indexing { return L("Scanning the folder…", "Сканирую папку…") }
        return model.query.isEmpty ? L("The folder is empty", "Папка пуста") : L("Nothing found", "Ничего не найдено")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.toast ?? statusText)
                .foregroundStyle(model.toast == nil ? Color.secondary : Color.accentColor)
            Spacer()
            Text(L("↵ open   ⌥↵ editor   ⌘↵ Finder   ⌘Y preview   ⇧⌘C path   Tab mode",
                   "↵ открыть   ⌥↵ редактор   ⌘↵ Finder   ⌘Y просмотр   ⇧⌘C путь   Tab режим"))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var statusText: String {
        let n = "\(model.indexedCount.formatted())\(model.truncated ? "+" : "")"
        let files = L("\(n) items", "\(n) объектов")
        switch model.mode {
        case .names:
            if model.indexing { return L("Scanning… \(files)", "Сканирую… \(files)") }
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                return L("Recently modified · \(files)", "Недавно изменённые · \(files)")
            }
            let found = model.totalMatches.formatted()
            return L("\(found) found · \(files)", "Найдено \(found) · \(files)")
        case .content:
            return model.searchingContent
                ? L("Searching files… \(model.hits.count)", "Ищу в файлах… \(model.hits.count)")
                : L("Files with the text: \(model.hits.count)", "Файлов с текстом: \(model.hits.count)")
        }
    }
}

struct HitRow: View {
    let hit: Hit
    let selected: Bool

    private static let dateFormatters: [Language: DateFormatter] = Dictionary(uniqueKeysWithValues: Language.allCases.map { lang in
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return (lang, f)
    })
    private static var dateFormatter: DateFormatter { dateFormatters[Settings.shared.language]! }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.icon(for: hit))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.parent.isEmpty ? L("in this folder", "в текущей папке") : hit.parent)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let snippet = hit.snippet {
                    Text((hit.line.map { "\($0):  " } ?? "") + snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.primary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if hit.date > 0 {
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: hit.date)))
                }
                if !hit.isDir || hit.isPackage, hit.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private var highlightedName: AttributedString {
        guard !hit.marks.isEmpty else { return AttributedString(hit.name) }
        var out = AttributedString()
        var offset = 0
        for ch in hit.name {
            var piece = AttributedString(String(ch))
            let len = ch.utf16.count
            if (offset..<offset + len).contains(where: hit.marks.contains) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                if !selected { piece.foregroundColor = Color.accentColor }
            }
            out.append(piece)
            offset += len
        }
        return out
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for hit: Hit) -> NSImage {
        let key: String
        let make: () -> NSImage
        if hit.isPackage {
            key = "p:" + hit.url.path
            make = { NSWorkspace.shared.icon(forFile: hit.url.path) }
        } else if hit.isDir {
            key = "dir"
            make = { NSWorkspace.shared.icon(for: .folder) }
        } else {
            let ext = hit.url.pathExtension.lowercased()
            key = "e:" + ext
            make = { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
        }
        if let img = cache[key] { return img }
        let img = make()
        cache[key] = img
        return img
    }
}

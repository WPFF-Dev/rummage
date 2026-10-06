# Rummage

**Fast file search inside the folder that is open in Finder.** Press a shortcut in Finder and a Spotlight-style
window searches that folder and all its subfolders as you type: by name (fuzzy) or by text inside files.

Finder's own search defaults to "This Mac", is slow and ranks results oddly. Rummage keeps the open folder
listed in memory (~120k files in about a second), searches it in a few milliseconds, and keeps results live as files change.

- Results while you type; case, accents and ё/е ignored; fuzzy: `invctrl` → `invoice-controller.php`
- Text inside files (grep with the matching line + Spotlight for PDF/DOCX); ↵ opens VS Code / Cursor **at that line**
- ⌘↵ selects the file in the same Finder window; Quick Look, copy path, open in Terminal, drag & drop
- Live updates via FSEvents: created, renamed, moved and deleted files show up without rescanning
- Menu bar app, no Dock icon; English and Russian UI (follows the macOS language)
- No dependencies, about 1,800 lines of Swift, universal binary (Apple Silicon + Intel), macOS 14+

## Install

1. Download `Rummage-x.y.z.zip` from [Releases](../../releases), unzip, move `Rummage.app` to Applications.
2. The app is not notarized by Apple, so the first launch is blocked. Either open
   System Settings → Privacy & Security and click **Open Anyway** next to Rummage, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Rummage.app
   ```
3. A magnifier icon appears in the menu bar. In Finder press **⌥⌘F**.
   When macOS asks "Rummage wants to control Finder", click **Allow**: that is how it learns which folder is open
   (System Settings → Privacy & Security → Automation).

### Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install   # build, copy to ~/Applications, launch
./build.sh dist      # build and zip into dist/ for sharing
```

## Usage

- By default the shortcut exists only while Finder is in front, so other apps keep ⌥⌘F. Change it in the menu
  (presets include replacing Finder's ⌘F).
- An empty query lists recently modified files.
- Filters: `ext:pdf,docx` or `*.pdf`, `kind:dir` / `kind:file`. A word with `/` matches the path: `themes/ header`.
- **Tab** switches between Names and Contents.

| Keys | Action |
|---|---|
| ↑ ↓, PgUp/PgDn | move selection |
| ↵ or ⌘↓ | open the file / open the folder in the Finder window; a Contents match opens in the code editor at the found line |
| ⌥↵ | open in the code editor (folders open as a project) |
| ⌘↵ | show and select in Finder (same window) |
| ⌘Y | Quick Look |
| ⇧⌘C | copy path |
| ⇧⌘T | open in Terminal |
| ⌘↑ | search the parent folder |
| ⌘→ | search inside the selected folder |
| Esc | close |

Right-click a result for the same actions; drag results into other apps.

**Menu bar menu:** shortcut, code editor (detected: VS Code, VS Code Insiders, Cursor, Antigravity, Windsurf),
language, "only in Finder", hidden files, skipping `node_modules`, `.git` and similar, launch at login.

## How it works

Swift + AppKit/SwiftUI, built with SwiftPM.

| File | Role |
|---|---|
| `HotKey.swift` | global shortcut via Carbon (no Accessibility permission needed) |
| `FinderBridge.swift` | AppleScript: folder of the front Finder window, reveal/select a file |
| `FileIndex.swift` | recursive in-memory listing, cache for 4 folders; `apply()` patches it from file events |
| `FolderWatcher.swift` | FSEvents on the current folder, kept running while the window is hidden |
| `Matcher.swift` | ranking: exact name > prefix > word boundary > substring > fuzzy > path match |
| `ContentSearch.swift` | text search: `grep` + `mdfind -onlyin` |
| `SearchModel.swift`, `SearchView.swift`, `SearchPanel.swift` | state, SwiftUI list, non-activating floating panel with Quick Look |
| `L10n.swift` | `L("English", "Русский")` strings, code editor URL schemes |

Debug helpers (after `./build.sh`):

```bash
.build/arm64-apple-macosx/release/Rummage --cli ~/Projects "query"   # index + search, timings
.build/arm64-apple-macosx/release/Rummage --watch-test /tmp/empty    # live-update self test
```

## License

MIT, see [LICENSE](LICENSE).

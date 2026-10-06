import AppKit
import Quartz
import SwiftUI

/// Spotlight-style floating panel. Non-activating: Finder stays the active app.
final class SearchPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: SearchModel
    var keepOpen = false

    init(model: SearchModel) {
        self.model = model
        let saved = NSSize(width: max(UserDefaults.standard.double(forKey: "panelW"), 760),
                           height: max(UserDefaults.standard.double(forKey: "panelH"), 500))
        super.init(contentRect: NSRect(origin: .zero, size: saved),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = NSSize(width: 620, height: 360)

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: SearchView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx

        model.onSelectionChange = { [weak self] in self?.refreshPreview() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if keepOpen || isPreviewVisible { return }
        hide()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = frame.size
            setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                   y: vf.maxY - vf.height * 0.16 - size.height))
        }
        model.panelVisible = true
        makeKeyAndOrderFront(nil)
    }

    func hide() {
        UserDefaults.standard.set(frame.width, forKey: "panelW")
        UserDefaults.standard.set(frame.height, forKey: "panelH")
        if isPreviewVisible { QLPreviewPanel.shared().orderOut(nil) }
        model.panelVisible = false
        orderOut(nil)
    }

    // MARK: Quick Look

    var isPreviewVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func togglePreview() {
        if isPreviewVisible {
            QLPreviewPanel.shared().orderOut(nil)
            makeKey()
        } else if model.selected != nil {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    private func refreshPreview() {
        if isPreviewVisible { QLPreviewPanel.shared().reloadData() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.selected == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        model.selected?.url as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 53, 49: togglePreview(); return true // esc, space
        default: return false
        }
    }
}

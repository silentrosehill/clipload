// Toast.swift — small pop-up in the top-right corner that doesn't steal focus,
// plus closure-based menu items and buttons for AppKit.

import AppKit

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

final class ActionButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(_ title: String, primary: Bool = false, _ handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .rounded
        controlSize = .small
        if primary { keyEquivalent = "\r" }
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Toast {
    private var panel: KeyPanel?
    private var timer: Timer?

    func show(_ title: String, _ subtitle: String, buttons: [(String, () -> Void)] = [], timeout: TimeInterval = 8) {
        dismiss()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle
        subLabel.maximumNumberOfLines = 2
        subLabel.preferredMaxLayoutWidth = 300

        var buttonViews: [NSView] = buttons.enumerated().map { i, b in
            ActionButton(b.0, primary: i == 0) { [weak self] in self?.dismiss(); b.1() }
        }
        buttonViews.append(ActionButton("Dismiss") { [weak self] in self?.dismiss() })
        let buttonRow = NSStackView(views: buttonViews)
        buttonRow.spacing = 6

        let stack = NSStackView(views: [titleLabel, subLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 330),
        ])

        let size = stack.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let frame = NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 12,
                           width: size.width, height: size.height)
        let p = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.contentView = blur
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.orderFrontRegardless()
        panel = p

        if timeout > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in self?.dismiss() }
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

let toast = Toast()

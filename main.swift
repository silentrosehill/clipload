// Clipload — downloads videos and streams with yt-dlp. Lives in the menu bar, watches the
// clipboard for video links, takes clipload:// links from the Stream Grabber userscript,
// and has a window with the download queue.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let manager = Manager.shared
    private let settings = Settings.shared
    private var lastChange = NSPasteboard.general.changeCount
    private var lastOffered = ""

    // MARK: Launch

    func applicationWillFinishLaunching(_ note: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        manager.onActivity = { [weak self] in self?.refreshStatus() }
        manager.onNeedsAttention = { [weak self] in self?.showWindow() }
        manager.onFinished = { [weak self] job in self?.notifyFinished(job) }
        refreshStatus()

        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.checkClipboard() }

        if ytdlpPath == nil {
            toast.show("yt-dlp isn't installed", "Clipload needs it. Install with: brew install yt-dlp ffmpeg", timeout: 0)
        }

        // Opened by hand → show the window. Started at login → stay in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Clipload"
            w.contentView = NSHostingView(rootView: MainView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ClipLoadMain")
            if !w.setFrameUsingName("ClipLoadMain") { w.center() }
            window = w
        }
        // Show a Dock icon while the window is open.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clipload", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ActionItem("Settings…", key: ",") { [weak self] in
            self?.showWindow()
            NotificationCenter.default.post(name: .showSettings, object: nil)
        })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Clipload", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Clipload", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addSubmenu("Clipload", appMenu)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addSubmenu("Edit", edit)

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addSubmenu("Window", win)
        NSApp.windowsMenu = win

        return main
    }

    // MARK: Clipboard

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard settings.clipMode != .off else { return }
        // Ignore copies made inside Clipload's own window (e.g. pasting into the link field).
        if NSApp.isActive { return }

        // Never look at passwords or other secrets copied from password managers.
        let types = pb.types ?? []
        let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if types.contains(where: { secret.contains($0.rawValue) }) { return }

        guard let text = pb.string(forType: .string), let url = linkFrom(text) else { return }
        guard settings.anyLink || isVideoLink(url) else { return }
        guard url.absoluteString != lastOffered else { return }
        lastOffered = url.absoluteString

        if settings.clipMode == .auto {
            manager.add(Request(url: url))
        } else {
            offer(Request(url: url))
        }
    }

    private func offer(_ req: Request) {
        let question = req.title.map { "Download “\($0)”?" } ?? "Download this video?"
        toast.show(question, req.url.absoluteString, buttons: [
            ("Download", { [weak self] in self?.manager.add(req) }),
            ("Audio only", { [weak self] in self?.manager.add(req, audio: true) }),
        ], timeout: 10)
    }

    // MARK: clipload:// links (sent by the Stream Grabber userscript)
    //
    //   clipload://download?url=<media or page>&referer=<page>&title=<title>&audio=1&token=<secret>

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s), comps.scheme == "clipload" else { return }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value }

        guard let raw = q["url"], let url = linkFrom(raw) else {
            toast.show("Clipload got an invalid link", s)
            return
        }
        let title = q["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = Request(url: url, referer: q["referer"].flatMap(linkFrom),
                          title: (title?.isEmpty ?? true) ? nil : title)
        if q["token"] == settings.token {
            manager.add(req, audio: q["audio"] == "1")
            if manager.jobs.first?.state != .probing {
                toast.show(q["audio"] == "1" ? "Added audio download" : "Added download", req.title ?? url.absoluteString, timeout: 3)
            }
        } else {
            offer(req)
        }
    }

    // MARK: Notifications

    private func notifyFinished(_ job: Job) {
        // The window already shows it.
        if window?.isKeyWindow == true && NSApp.isActive { return }
        if job.state == .done, let file = job.file {
            toast.show("Downloaded", job.title, buttons: [
                ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }),
                ("Open", { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }),
            ])
        } else if job.state == .failed {
            toast.show("Couldn't download", job.error, buttons: [
                ("Retry", { [weak self] in self?.manager.retry(job) }),
                ("Open Clipload", { [weak self] in self?.showWindow() }),
            ], timeout: 12)
        }
    }

    // MARK: Menu bar

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let running = manager.running
        let queued = manager.queuedCount
        let symbol = settings.clipMode == .off ? "pause.circle"
            : (running.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clipload")
        if running.isEmpty {
            button.title = ""
        } else {
            let avg = running.map(\.percent).reduce(0, +) / Double(running.count)
            button.title = " \(Int(avg))%" + (queued > 0 ? " +\(queued)" : "")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ActionItem("Open Clipload") { [weak self] in self?.showWindow() })
        menu.addItem(.separator())

        let active = manager.jobs.filter { !$0.state.isFinished }
        for job in active.prefix(8) {
            let state: String
            switch job.state {
            case .running: state = "\(Int(job.percent))%"
            case .queued: state = "queued"
            case .probing: state = "checking…"
            case .choosing: state = "pick a quality"
            default: state = ""
            }
            menu.addItem(ActionItem("\(job.title) — \(state)") { [weak self] in self?.showWindow() })
        }
        if !active.isEmpty {
            menu.addItem(ActionItem("Cancel All") { [weak self] in self?.manager.cancelAll() })
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem("Download Link from Clipboard") { [weak self] in
            if let s = NSPasteboard.general.string(forType: .string), let url = linkFrom(s) {
                self?.manager.add(Request(url: url))
            } else {
                toast.show("No link on the clipboard", "Copy a video link first.")
            }
        })
        menu.addItem(.separator())

        let clip = NSMenu()
        for mode in ClipMode.allCases {
            clip.addItem(ActionItem(mode.label, checked: settings.clipMode == mode) { [weak self] in
                self?.settings.clipMode = mode
                self?.refreshStatus()
            })
        }
        menu.addSubmenu("When I Copy a Link", clip)

        let quality = NSMenu()
        for q in Quality.allCases {
            quality.addItem(ActionItem(q.label, checked: settings.quality == q) { [weak self] in
                self?.settings.quality = q
            })
        }
        menu.addSubmenu("Default Quality", quality)

        menu.addItem(ActionItem("Settings…") { [weak self] in
            self?.showWindow()
            NotificationCenter.default.post(name: .showSettings, object: nil)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Clipload") { NSApp.terminate(nil) })
    }
}

extension NSMenu {
    func addSubmenu(_ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

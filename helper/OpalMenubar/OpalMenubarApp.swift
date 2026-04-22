import AppKit
import Foundation

// Opal menubar helper. Talks to Opal core over local HTTP API on :41595.
// Core spawns the API when user enables "Web Remote Control" in settings.

let API_PORT = 41595
let POLL_INTERVAL: TimeInterval = 2.0

struct Status {
    var title: String = "Opal"
    var paused: Bool = true
    var pos: Double = 0
    var dur: Double = 0
    var vol: Double = 0
    var reachable: Bool = false
}

final class OpalClient {
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        return URLSession(configuration: cfg)
    }()

    func call(_ path: String, completion: ((Data?) -> Void)? = nil) {
        guard let url = URL(string: "http://127.0.0.1:\(API_PORT)/api\(path)") else { return }
        let task = session.dataTask(with: url) { data, _, _ in completion?(data) }
        task.resume()
    }

    func fetchStatus(_ completion: @escaping (Status) -> Void) {
        call("/status") { data in
            var s = Status()
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                completion(s); return
            }
            s.reachable = true
            s.title = (obj["title"] as? String) ?? "Opal"
            s.paused = (obj["paused"] as? Bool) ?? true
            s.pos = (obj["pos"] as? Double) ?? 0
            s.dur = (obj["dur"] as? Double) ?? 0
            s.vol = (obj["vol"] as? Double) ?? 0
            completion(s)
        }
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let client = OpalClient()
    private var status = Status()
    private var timer: Timer?

    // Menu item refs for live updates.
    private let titleItem = NSMenuItem(title: "Opal — not running", action: nil, keyEquivalent: "")
    private let posItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Play", action: #selector(toggle), keyEquivalent: "p")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            // Emoji + text — maximally distinctive for notched menu bars.
            button.title = "💎 Opal"
            button.image = nil
            button.imagePosition = .noImage
        }
        statusItem.menu = buildMenu()
        startPolling()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        titleItem.isEnabled = false
        posItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(posItem)
        menu.addItem(NSMenuItem.separator())

        toggleItem.target = self
        menu.addItem(toggleItem)

        let back = NSMenuItem(title: "◀  -10s", action: #selector(seekBack), keyEquivalent: "[")
        back.target = self
        menu.addItem(back)

        let fwd = NSMenuItem(title: "▶  +10s", action: #selector(seekFwd), keyEquivalent: "]")
        fwd.target = self
        menu.addItem(fwd)

        menu.addItem(NSMenuItem.separator())

        let volUp = NSMenuItem(title: "Volume +5", action: #selector(volUp), keyEquivalent: "=")
        volUp.target = self
        menu.addItem(volUp)

        let volDown = NSMenuItem(title: "Volume -5", action: #selector(volDown), keyEquivalent: "-")
        volDown.target = self
        menu.addItem(volDown)

        let mute = NSMenuItem(title: "Mute", action: #selector(muteToggle), keyEquivalent: "m")
        mute.target = self
        menu.addItem(mute)

        menu.addItem(NSMenuItem.separator())

        let open = NSMenuItem(title: "Open Opal", action: #selector(openOpalAction), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Menubar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: POLL_INTERVAL, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        client.fetchStatus { [weak self] s in
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    private func apply(_ s: Status) {
        status = s
        if !s.reachable {
            titleItem.title = "Opal — not running"
            posItem.title = "Enable Web Remote in settings"
            toggleItem.title = "Play"
            toggleItem.isEnabled = false
            statusItem.button?.title = "💎 Opal"
            return
        }
        toggleItem.isEnabled = true
        titleItem.title = s.title.isEmpty ? "No media" : s.title
        posItem.title = String(format: "%@  •  %@/%@  •  vol %.0f",
                               s.paused ? "paused" : "playing",
                               fmtTime(s.pos), fmtTime(s.dur), s.vol)
        toggleItem.title = s.paused ? "Play" : "Pause"
        statusItem.button?.title = s.paused ? "💎 Opal" : "▶ " + truncate(s.title, max: 28)
    }

    private func fmtTime(_ sec: Double) -> String {
        if sec.isNaN || sec < 0 { return "0:00" }
        let total = Int(sec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    // ── Menu actions ──
    @objc private func toggle() { client.call("/toggle"); refresh() }
    @objc private func seekBack() { client.call("/back"); refresh() }
    @objc private func seekFwd() { client.call("/fwd"); refresh() }
    @objc private func volUp() { client.call("/vol_up"); refresh() }
    @objc private func volDown() { client.call("/vol_down"); refresh() }
    @objc private func muteToggle() { client.call("/mute"); refresh() }

    @objc private func openOpalAction() { openOpal(jumpToSettings: false) }

    @objc private func openSettings() { openOpal(jumpToSettings: true) }

    private func openOpal(jumpToSettings: Bool) {
        guard let path = resolveOpalPath() else {
            promptForOpalLocation()
            return
        }
        // Remote reachable → ask core to show settings without app switch noise.
        if jumpToSettings && status.reachable {
            client.call("/settings/open")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        // If opening to settings but remote not yet up, wait for boot, then push.
        if jumpToSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.client.call("/settings/open")
            }
        }
    }

    private func resolveOpalPath() -> String? {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "OpalAppPath"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let candidates = [
            "/Applications/Opal.app",
            NSString("~/Applications/Opal.app").expandingTildeInPath,
            NSString("~/Desktop/Opal/dist/Opal.app").expandingTildeInPath,
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            defaults.set(path, forKey: "OpalAppPath")
            return path
        }
        // Try LaunchServices lookup by bundle id.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.debpalash.opal") {
            defaults.set(url.path, forKey: "OpalAppPath")
            return url.path
        }
        return nil
    }

    private func promptForOpalLocation() {
        let alert = NSAlert()
        alert.messageText = "Opal not found"
        alert.informativeText = "The Opal app could not be located. Locate it manually, or install it first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.title = "Select Opal.app"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "OpalAppPath")
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

// ── Entry point ──
@main
struct OpalMenubarApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no dock icon, menubar only
        let controller = StatusController()
        _ = controller  // retain
        app.run()
    }
}

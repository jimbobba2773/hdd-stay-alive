import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard
    var assertionID: IOPMAssertionID = 0
    var diskAssertionID: IOPMAssertionID = 0
    let pingQueue = DispatchQueue(label: "pings", qos: .utility)
    var readTargets: [String: String] = [:]   // volume path -> file we read from (pingQueue only)

    enum Method: String, CaseIterable {
        case read, write, both
        var title: String {
            switch self {
            case .read: return "Read (no changes to the drive)"
            case .write: return "Write a tiny file"
            case .both: return "Read and write"
            }
        }
    }
    var method: Method {
        get { Method(rawValue: defaults.string(forKey: "method") ?? "") ?? .read }
        set { defaults.set(newValue.rawValue, forKey: "method") }
    }
    var timer: Timer?
    var active = false
    var refreshing = false

    // Volumes the user picked (by path). Stored in UserDefaults.
    var selected: Set<String> {
        get { Set(defaults.stringArray(forKey: "volumes") ?? []) }
        set { defaults.set(Array(newValue), forKey: "volumes") }
    }
    var interval: Double {
        get { let v = defaults.double(forKey: "interval"); return v > 0 ? v : 30 }
        set { defaults.set(newValue, forKey: "interval") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Enable launch-at-login the first time the app runs; after that the menu toggle decides.
        if !defaults.bool(forKey: "loginConfigured") {
            defaults.set(true, forKey: "loginConfigured")
            try? SMAppService.mainApp.register()
        }
        updateIcon()
        rebuildMenu()
        start()   // active as soon as the app opens
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.rebuildMenu() }
        }
    }

    func applicationWillTerminate(_ n: Notification) { stop() }

    // MARK: Keep-alive

    func start() {
        guard !active else { return }
        active = true
        // Stop the system and disks from idle-sleeping.
        IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "HDD Stay Alive" as CFString, &assertionID)
        // Also stop macOS spinning down external disks under its own disk-sleep timer.
        IOPMAssertionCreateWithName("PreventDiskIdle" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "HDD Stay Alive (disks)" as CFString, &diskAssertionID)
        ping()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.ping() }
        updateIcon(); rebuildMenu()
    }

    func stop() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        if diskAssertionID != 0 { IOPMAssertionRelease(diskAssertionID); diskAssertionID = 0 }
        updateIcon(); rebuildMenu()
    }

    /// Gives each selected drive some real I/O so it doesn't spin down.
    func ping() {
        let method = self.method
        pingQueue.async { [selected] in
            for path in selected where FileManager.default.fileExists(atPath: path) {
                var touched = false
                if method != .write { touched = self.readTouch(path) }
                // Write mode, or fall back to it when there was nothing to read (e.g. an empty drive).
                if method != .read || !touched { self.writeTouch(path) }
            }
        }
    }

    func writeTouch(_ volume: String) {
        let url = URL(fileURLWithPath: volume).appendingPathComponent(".hdd-stay-alive")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        try? h.write(contentsOf: Data("\(Date().timeIntervalSince1970)".utf8))
        try? h.synchronize()   // fsync: forces a real write to the disk
        try? h.close()
    }

    /// Reads one block from a random spot in an existing file, bypassing the cache so the disk is really hit.
    func readTouch(_ volume: String) -> Bool {
        if let f = readTargets[volume], FileManager.default.fileExists(atPath: f), readBlock(f) { return true }
        guard let f = findReadableFile(volume) else { return false }
        readTargets[volume] = f
        return readBlock(f)
    }

    func readBlock(_ file: String) -> Bool {
        let fd = open(file, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return false }
        let block = 4096
        let offset = off_t(Int.random(in: 0...Int(st.st_size - 1)) / block * block)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: block)
        defer { buf.deallocate() }
        return pread(fd, buf, block, offset) > 0
    }

    /// Finds a file to read from: prefers one of at least 1 MB, otherwise any non-empty file.
    func findReadableFile(_ volume: String) -> String? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: volume),
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var fallback: String?, seen = 0
        for case let u as URL in e {
            seen += 1
            if seen > 3000 { break }
            if e.level > 4 { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, size > 0 else { continue }
            if size >= 1_048_576 { return u.path }
            if fallback == nil { fallback = u.path }
        }
        return fallback
    }

    // MARK: UI

    /// Menu bar glyph matching the app icon: drive with status light and heartbeat line.
    /// Outlined when off, solid when on. Template image, so macOS tints it for light/dark.
    func menuBarImage(on: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            // Heartbeat line
            let hb = NSBezierPath()
            let y = 14.5
            hb.move(to: NSPoint(x: 2, y: y))
            hb.line(to: NSPoint(x: 7, y: y))
            hb.line(to: NSPoint(x: 9, y: y + 2.5))
            hb.line(to: NSPoint(x: 11.5, y: y - 2.5))
            hb.line(to: NSPoint(x: 13, y: y))
            hb.line(to: NSPoint(x: 20, y: y))
            hb.lineWidth = 1.4; hb.lineCapStyle = .round; hb.lineJoinStyle = .round
            NSColor.black.setStroke(); hb.stroke()

            // Drive body
            let body = NSRect(x: 2, y: 1.5, width: 18, height: 9.5)
            let drive = NSBezierPath(roundedRect: body.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.2, yRadius: 2.2)
            drive.lineWidth = 1.5
            NSColor.black.set()
            if on { drive.fill() } else { drive.stroke() }

            // Slot lines + status light (knocked out when solid, drawn when outlined)
            if on { NSGraphicsContext.current?.compositingOperation = .destinationOut }
            for i in 0..<2 {
                NSBezierPath(roundedRect: NSRect(x: 5, y: 3.7 + Double(i) * 2.4, width: 7, height: 1.1),
                             xRadius: 0.5, yRadius: 0.5).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 15.2, y: 3.6, width: 2.2, height: 2.2)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "HDD Stay Alive"
        return img
    }

    func updateIcon() {
        statusItem.button?.image = menuBarImage(on: active)
        statusItem.button?.toolTip = active ? "Keeping drives awake" : "Drives may sleep"
    }

    func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return vols.filter { $0.path != "/" && $0.path.hasPrefix("/Volumes/") }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: active ? "Stay Alive: ON" : "Stay Alive: OFF",
                                action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        toggle.state = active ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let hideInactive = defaults.bool(forKey: "hideInactive")
        menu.addItem(withTitle: hideInactive ? "Active drives:" : "Drives to keep awake:",
                     action: nil, keyEquivalent: "").isEnabled = false
        let vols = externalVolumes()
        let mounted = Set(vols.map { $0.path })

        func driveItem(_ path: String, connected: Bool) -> NSMenuItem {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let item = NSMenuItem(title: connected ? name : "\(name) (not connected)",
                                  action: #selector(toggleVolume(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = selected.contains(path) ? .on : .off
            return item
        }

        // Remembered drives that aren't mounted right now stay listed so they can be unticked.
        let missing = selected.subtracting(mounted).sorted()
        let shown = vols.map { $0.path }.filter { !hideInactive || selected.contains($0) }
        for p in missing { menu.addItem(driveItem(p, connected: false)) }
        for p in shown { menu.addItem(driveItem(p, connected: true)) }
        if missing.isEmpty && shown.isEmpty {
            menu.addItem(withTitle: hideInactive ? "  (none selected)" : "  (none found)",
                         action: nil, keyEquivalent: "").isEnabled = false
        }

        // When inactive drives are hidden, they can still be browsed (and picked) from a submenu.
        if hideInactive {
            let others = vols.map { $0.path }.filter { !selected.contains($0) }
            let browse = NSMenuItem(title: "Other Drives", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for p in others { sub.addItem(driveItem(p, connected: true)) }
            if others.isEmpty { sub.addItem(withTitle: "(none)", action: nil, keyEquivalent: "").isEnabled = false }
            browse.submenu = sub
            menu.addItem(browse)
        }
        let refresh = NSMenuItem(title: refreshing ? "Refreshing…" : "Refresh Drives",
                                 action: refreshing ? nil : #selector(refreshDrives), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let sub = NSMenu()
        for s in [10.0, 30, 60, 120] {
            let i = NSMenuItem(title: "Every \(Int(s)) seconds", action: #selector(setInterval(_:)), keyEquivalent: "")
            i.target = self; i.tag = Int(s); i.state = interval == s ? .on : .off
            sub.addItem(i)
        }
        let methodMenu = NSMenu()
        for m in Method.allCases {
            let i = NSMenuItem(title: m.title, action: #selector(setMethod(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = m.rawValue; i.state = method == m ? .on : .off
            methodMenu.addItem(i)
        }
        let methodItem = NSMenuItem(title: "Keep-alive method", action: nil, keyEquivalent: "")
        methodItem.submenu = methodMenu
        menu.addItem(methodItem)

        let intervalItem = NSMenuItem(title: "Activity interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = sub
        menu.addItem(intervalItem)

        let hide = NSMenuItem(title: "Only Show Active Drives", action: #selector(toggleHideInactive), keyEquivalent: "")
        hide.target = self
        hide.state = hideInactive ? .on : .off
        menu.addItem(hide)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(withTitle: "HDD Stay Alive v\(version)", action: nil, keyEquivalent: "").isEnabled = false
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc func toggleActive() { active ? stop() : start() }

    @objc func toggleVolume(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        var sel = selected
        if sel.contains(p) { sel.remove(p) } else { sel.insert(p) }
        selected = sel
        if active { ping() }
        rebuildMenu()
    }

    @objc func setInterval(_ s: NSMenuItem) {
        interval = Double(s.tag)
        if active { timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.ping() } }
        rebuildMenu()
    }

    /// Asks macOS to mount any external disk that is attached but not mounted, then reloads the list.
    @objc func refreshDrives() {
        refreshing = true
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func diskutil(_ args: [String]) -> Data {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = args
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                try? p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return data
            }
            let plist = try? PropertyListSerialization.propertyList(
                from: diskutil(["list", "-plist", "external", "physical"]), format: nil) as? [String: Any]
            let disks = (plist?["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
            for d in disks {
                if let id = d["DeviceIdentifier"] as? String { _ = diskutil(["mountDisk", "/dev/\(id)"]) }
            }
            DispatchQueue.main.async {
                self?.refreshing = false
                self?.rebuildMenu()
            }
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login item"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        rebuildMenu()
    }

    @objc func setMethod(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let m = Method(rawValue: raw) else { return }
        method = m
        if active { ping() }
        rebuildMenu()
    }

    @objc func toggleHideInactive() {
        defaults.set(!defaults.bool(forKey: "hideInactive"), forKey: "hideInactive")
        rebuildMenu()
    }

    // MARK: Updates

    /// Compares dotted version strings numerically ("1.10" > "1.9").
    func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func alert(_ title: String, _ text: String, openURL: URL? = nil, button: String = "Download") {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if openURL != nil { a.addButton(withTitle: button); a.addButton(withTitle: "Later") }
        if a.runModal() == .alertFirstButtonReturn, let u = openURL { NSWorkspace.shared.open(u) }
    }

    /// Looks at the latest GitHub release of the repo set as UpdateRepo (owner/repo) in Info.plist.
    @objc func checkForUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let repo = defaults.string(forKey: "updateRepo")
            ?? (Bundle.main.infoDictionary?["UpdateRepo"] as? String) ?? ""
        guard !repo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            alert("Updates aren't set up", "No GitHub repository is configured for this app yet.\nSet REPO in build.sh and rebuild.")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let err = err { self.alert("Couldn't check for updates", err.localizedDescription); return }
                if code == 404 { self.alert("No releases yet", "\(repo) has no published releases."); return }
                guard code == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.alert("Couldn't check for updates", "GitHub returned an unexpected response (\(code)).")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if self.isNewer(latest, than: current) {
                    let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                    self.alert("Version \(latest) is available", "You have version \(current).", openURL: page)
                } else {
                    self.alert("You're up to date", "HDD Stay Alive \(current) is the latest version.")
                }
            }
        }.resume()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }   // refresh drive list on open
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

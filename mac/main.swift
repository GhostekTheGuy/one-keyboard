// Jedna Klawiatura - strona Maca.
// Klawiatura Maca pisze tam, gdzie ostatnio ruszono myszą:
// gładzik/mysz Maca -> Mac, mysz Windowsa -> Windows (agent zgłasza ruch).
// Protokół (linie tekstu po TCP, port 24850):
//   Mac -> Win: "U 0105 ..." znaki Unicode (UTF-16 hex), "K vk down mods ext" klawisz VK,
//               "R" puść wszystko, "F 0|1" fokus, "P" ping
//   Win -> Mac: "H nazwa" powitanie, "M" ruch myszy Windowsa, "P" ping

import Cocoa
import Network
import Carbon

let kPort: UInt16 = 24850
let macMoveThreshold = 30.0   // punkty ruchu gładzika, żeby wrócić na Maca

enum Mode { case mac, win }

// Kody klawiszy Maca (pozycje ANSI) -> Windows Virtual-Key
let vkMap: [Int64: Int] = [
    0: 0x41, 11: 0x42, 8: 0x43, 2: 0x44, 14: 0x45, 3: 0x46, 5: 0x47, 4: 0x48, 34: 0x49,
    38: 0x4A, 40: 0x4B, 37: 0x4C, 46: 0x4D, 45: 0x4E, 31: 0x4F, 35: 0x50, 12: 0x51,
    15: 0x52, 1: 0x53, 17: 0x54, 32: 0x55, 9: 0x56, 13: 0x57, 7: 0x58, 16: 0x59, 6: 0x5A,
    29: 0x30, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35, 22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39,
    41: 0xBA, 24: 0xBB, 43: 0xBC, 27: 0xBD, 47: 0xBE, 44: 0xBF, 50: 0xC0, 33: 0xDB, 42: 0xDC,
    30: 0xDD, 39: 0xDE, 10: 0xE2,
    36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B, 76: 0x0D,
    117: 0x2E, 114: 0x2D, 115: 0x24, 119: 0x23, 116: 0x21, 121: 0x22,
    123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
    122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73, 96: 0x74, 97: 0x75, 98: 0x76, 100: 0x77,
    101: 0x78, 109: 0x79, 103: 0x7A, 111: 0x7B,
    82: 0x60, 83: 0x61, 84: 0x62, 85: 0x63, 86: 0x64, 87: 0x65, 88: 0x66, 89: 0x67, 91: 0x68, 92: 0x69,
    67: 0x6A, 69: 0x6B, 78: 0x6D, 65: 0x6E, 75: 0x6F, 71: 0x0C, 81: 0xBB,
]

// Klawisze, które zawsze idą jako VK (nie jako znak)
let specialKeys: Set<Int64> = [36, 48, 49, 51, 53, 76, 117, 114, 115, 119, 116, 121, 123, 124, 125, 126,
                               122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 71]

let extendedVk: Set<Int> = [0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x6F]

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var listener: NWListener?
    var conn: NWConnection?
    var peerName = ""
    var mode: Mode = .mac
    var tap: CFMachPort?
    var lastPeerData = Date()
    var moveAcc = 0.0
    var lastMove = Date.distantPast
    var unicodeDown = Set<Int64>()
    var vkDown: [Int64: (vk: Int, mods: Int, ext: Int)] = [:]
    var rx = Data()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(infoItem)
        menu.addItem(.separator())
        let w = NSMenuItem(title: "Klawiatura na Windows", action: #selector(forceWin), keyEquivalent: "")
        let m = NSMenuItem(title: "Klawiatura na Maca", action: #selector(forceMac), keyEquivalent: "")
        let q = NSMenuItem(title: "Zakończ", action: #selector(quit), keyEquivalent: "q")
        for i in [w, m] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
        startListener()
        ensureTap()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { app.tick() }
        }
    }

    @objc func forceWin() { setMode(.win) }
    @objc func forceMac() { setMode(.mac) }
    @objc func quit() { send("R"); NSApp.terminate(nil) }

    // MARK: - stan

    func refresh() {
        let title: String
        if tap == nil { title = "⌨ !" }
        else if conn == nil { title = "⌨ -" }
        else { title = mode == .win ? "⌨ WIN" : "⌨ MAC" }
        statusItem.button?.title = title
        if tap == nil {
            infoItem.title = "Brak uprawnienia Dostępność"
        } else if conn == nil {
            infoItem.title = "Czekam na Windowsa (port \(kPort))"
        } else {
            infoItem.title = "Połączono: \(peerName) - klawiatura: \(mode == .win ? "Windows" : "Mac")"
        }
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        if m == .win && conn == nil { return }
        if mode == .win {
            send("R")
            unicodeDown.removeAll()
            vkDown.removeAll()
        }
        mode = m
        moveAcc = 0
        send(m == .win ? "F 1" : "F 0")
        refresh()
    }

    func tick() {
        send("P")
        if conn != nil && Date().timeIntervalSince(lastPeerData) > 7 {
            conn?.cancel()
            dropConn()
        }
        if tap == nil { ensureTap() }
        else if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    // MARK: - sieć

    func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: kPort)!) else {
            infoItem.title = "Nie mogę otworzyć portu \(kPort)"
            return
        }
        l.newConnectionHandler = { c in
            MainActor.assumeIsolated { app.accept(c) }
        }
        l.stateUpdateHandler = { st in
            if case .failed = st {
                MainActor.assumeIsolated {
                    app.listener?.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { app.startListener() }
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func accept(_ c: NWConnection) {
        conn?.cancel()
        dropConn()
        conn = c
        rx = Data()
        lastPeerData = Date()
        c.stateUpdateHandler = { st in
            MainActor.assumeIsolated {
                switch st {
                case .failed, .cancelled:
                    if app.conn === c { app.dropConn() }
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(c)
        refresh()
    }

    func dropConn() {
        if mode == .win {
            mode = .mac
            unicodeDown.removeAll()
            vkDown.removeAll()
        }
        conn = nil
        peerName = ""
        refresh()
    }

    func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, err in
            MainActor.assumeIsolated {
                guard app.conn === c else { return }
                if let d = data, !d.isEmpty { app.consume(d) }
                if done || err != nil { c.cancel(); app.dropConn(); return }
                app.receive(c)
            }
        }
    }

    func consume(_ d: Data) {
        lastPeerData = Date()
        rx.append(d)
        while let nl = rx.firstIndex(of: 0x0A) {
            let lineData = rx[rx.startIndex..<nl]
            rx.removeSubrange(rx.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }
            if line.hasPrefix("H ") {
                peerName = String(line.dropFirst(2))
                refresh()
            } else if line == "M" {
                setMode(.win)
            }
        }
    }

    func send(_ s: String) {
        guard let c = conn else { return }
        c.send(content: (s + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - przechwytywanie

    func ensureTap() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { refresh(); return }
        let types: [CGEventType] = [.keyDown, .keyUp, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        let cb: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated { app.handle(type: type, event: event) }
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: cb, userInfo: nil) else { refresh(); return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        refresh()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if mode == .win {
                let now = Date()
                if now.timeIntervalSince(lastMove) > 0.4 { moveAcc = 0 }
                lastMove = now
                moveAcc += abs(event.getDoubleValueField(.mouseEventDeltaX)) + abs(event.getDoubleValueField(.mouseEventDeltaY))
                if moveAcc > macMoveThreshold { setMode(.mac) }
            }
            return pass
        case .scrollWheel:
            // bezwładność przewijania po puszczeniu palców nie przełącza
            if mode == .win && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 { setMode(.mac) }
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if mode == .win { setMode(.mac) }
            return pass
        case .keyDown, .keyUp:
            guard mode == .win, conn != nil else { return pass }
            return forwardKey(down: type == .keyDown, event: event) ? nil : pass
        default:
            return pass
        }
    }

    var deadKeyState: UInt32 = 0

    /// Znak z bieżącego układu klawiatury Maca (np. Polish Pro: Option+a = ą).
    func translate(keyCode: Int64, flags: CGEventFlags) -> [UniChar]? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var carbon: UInt32 = 0
        if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if flags.contains(.maskAlphaShift) { carbon |= UInt32(alphaLock) }
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), (carbon >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()), 0, &deadKeyState, 8, &len, &buf)
        }
        return status == noErr ? Array(buf.prefix(len)) : nil
    }

    /// Zwraca true, jeśli zdarzenie poszło na Windowsa (i trzeba je połknąć na Macu).
    func forwardKey(down: Bool, event: CGEvent) -> Bool {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if !down {
            if unicodeDown.remove(kc) != nil { return true }
            if let d = vkDown.removeValue(forKey: kc) {
                send("K \(d.vk) 0 \(d.mods) \(d.ext)")
                return true
            }
            return false // klawisz wciśnięty jeszcze na Macu: niech Mac go puści
        }
        let f = event.flags
        let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl)
        let opt = f.contains(.maskAlternate), shift = f.contains(.maskShift)

        if !cmd && !ctrl && !specialKeys.contains(kc) {
            var units = translate(keyCode: kc, flags: f)
            if units == nil {
                var len = 0
                var buf = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
                units = Array(buf.prefix(len))
            }
            if units!.isEmpty && deadKeyState != 0 {
                unicodeDown.insert(kc) // klawisz martwy: czekamy na następną literę
                return true
            }
            let printable = units!.filter { $0 >= 0x20 && $0 != 0x7F }
            if !printable.isEmpty {
                send("U " + printable.map { String(format: "%04X", $0) }.joined(separator: " "))
                unicodeDown.insert(kc)
                return true
            }
        }

        guard var vk = vkMap[kc] else { return true } // nieznany klawisz: połknij
        var mods = 0
        if shift { mods |= 1 }
        if cmd || ctrl { mods |= 2 }
        if opt { mods |= 4 }

        // Edycja jak na Macu
        if [123, 124, 125, 126].contains(kc) {
            if cmd {
                mods &= ~2
                switch kc {
                case 123: vk = 0x24               // Cmd+← = Home
                case 124: vk = 0x23               // Cmd+→ = End
                case 126: vk = 0x24; mods |= 2    // Cmd+↑ = Ctrl+Home
                default: vk = 0x23; mods |= 2     // Cmd+↓ = Ctrl+End
                }
            } else if opt {
                mods = (mods & ~4) | 2            // Opt+strzałka = Ctrl+strzałka (po słowie)
            }
        }
        if kc == 51 && opt { mods = (mods & ~4) | 2 } // Opt+Backspace = Ctrl+Backspace
        if kc == 49 { mods &= ~4 }                     // Opt+spacja to zwykła spacja

        let ext = (extendedVk.contains(vk) || kc == 76) ? 1 : 0
        vkDown[kc] = (vk, mods, ext)
        send("K \(vk) 1 \(mods) \(ext)")
        return true
    }
}

let app = App()
let nsapp = NSApplication.shared
nsapp.delegate = app
nsapp.setActivationPolicy(.accessory)
nsapp.run()

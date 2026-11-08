// Jedna Klawiatura (gałąź windows-keyboard) - strona Maca.
// Odwrotnie niż na main: klawiatura laptopa z Windowsem pisze na Macu, kiedy ostatnio
// ruszono myszą/gładzikiem Maca. Ruch myszy Windowsa oddaje klawiaturę Windowsowi.
// Windows przechwytuje klawisze, Mac je wpisuje i zgłasza ruch swojej myszy.
// Protokół (linie tekstu po TCP, port 24850; Mac nasłuchuje, Windows się łączy):
//   Win -> Mac: "H nazwa" powitanie, "U 0105 ..." znaki Unicode (UTF-16 hex),
//               "K vk down mods ext" klawisz Windows VK (mods: 1 shift, 2 ctrl, 4 alt, 8 win),
//               "R" puść wszystko, "F 0|1" klawiatura na Macu, "P" ping
//   Mac -> Win: "M" ruch myszy Maca (weź klawiaturę), "X" oddaj klawiaturę Windowsowi, "P" ping

import Cocoa
import Network

let kPort: UInt16 = 24850
let macMoveThreshold = 30.0   // punkty ruchu gładzika, żeby przejąć klawiaturę

// Kody klawiszy Maca (pozycje ANSI) -> Windows Virtual-Key; tu używane odwrotnie
let vkMap: [Int64: Int] = [
    0: 0x41, 11: 0x42, 8: 0x43, 2: 0x44, 14: 0x45, 3: 0x46, 5: 0x47, 4: 0x48, 34: 0x49,
    38: 0x4A, 40: 0x4B, 37: 0x4C, 46: 0x4D, 45: 0x4E, 31: 0x4F, 35: 0x50, 12: 0x51,
    15: 0x52, 1: 0x53, 17: 0x54, 32: 0x55, 9: 0x56, 13: 0x57, 7: 0x58, 16: 0x59, 6: 0x5A,
    29: 0x30, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35, 22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39,
    41: 0xBA, 24: 0xBB, 43: 0xBC, 27: 0xBD, 47: 0xBE, 44: 0xBF, 50: 0xC0, 33: 0xDB, 42: 0xDC,
    30: 0xDD, 39: 0xDE, 10: 0xE2,
    36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B,
    117: 0x2E, 114: 0x2D, 115: 0x24, 119: 0x23, 116: 0x21, 121: 0x22,
    123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
    122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73, 96: 0x74, 97: 0x75, 98: 0x76, 100: 0x77,
    101: 0x78, 109: 0x79, 103: 0x7A, 111: 0x7B,
    82: 0x60, 83: 0x61, 84: 0x62, 85: 0x63, 86: 0x64, 87: 0x65, 88: 0x66, 89: 0x67, 91: 0x68, 92: 0x69,
    67: 0x6A, 69: 0x6B, 78: 0x6D, 65: 0x6E, 75: 0x6F, 71: 0x0C,
]
// Windows VK -> kod klawisza Maca
let macKey: [Int: CGKeyCode] = Dictionary(vkMap.map { ($0.value, CGKeyCode($0.key)) }, uniquingKeysWith: { a, _ in a })

// kody Maca używane przy tłumaczeniu skrótów
let kLeft: CGKeyCode = 123, kRight: CGKeyCode = 124, kDown: CGKeyCode = 125, kUp: CGKeyCode = 126

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var listener: NWListener?
    var conn: NWConnection?
    var peerName = ""
    /// Windows zgłasza, gdzie idzie jego klawiatura ("F 1" = na Maca)
    var onMac = false
    var tap: CFMachPort?
    var lastPeerData = Date()
    var moveAcc = 0.0
    var lastMove = Date.distantPast
    var lastRequest = Date.distantPast
    /// klawisze wciśnięte przez Windows: id (vk + ext) -> to, co wcisnęliśmy na Macu
    var down: [Int: (code: CGKeyCode, flags: CGEventFlags)] = [:]
    var rx = Data()
    let source = CGEventSource(stateID: .hidSystemState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(infoItem)
        menu.addItem(.separator())
        let m = NSMenuItem(title: "Klawiatura Windowsa na Maca", action: #selector(takeKeyboard), keyEquivalent: "")
        let w = NSMenuItem(title: "Oddaj klawiaturę Windowsowi", action: #selector(giveBack), keyEquivalent: "")
        let q = NSMenuItem(title: "Zakończ", action: #selector(quit), keyEquivalent: "q")
        for i in [m, w] { i.target = self; menu.addItem(i) }
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

    @objc func takeKeyboard() { send("M") }
    @objc func giveBack() { send("X") }
    @objc func quit() { send("X"); releaseAll(); NSApp.terminate(nil) }

    // MARK: - stan

    func refresh() {
        let title: String
        if tap == nil { title = "⌨ !" }
        else if conn == nil { title = "⌨ -" }
        else { title = onMac ? "⌨ MAC" : "⌨ WIN" }
        statusItem.button?.title = title
        if tap == nil {
            infoItem.title = "Brak uprawnienia Dostępność"
        } else if conn == nil {
            infoItem.title = "Czekam na Windowsa (port \(kPort))"
        } else {
            infoItem.title = "Połączono: \(peerName) - klawiatura Windowsa pisze na: \(onMac ? "Macu" : "Windowsie")"
        }
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
        releaseAll()
        onMac = false
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
            handle(line)
        }
    }

    func handle(_ line: String) {
        let p = line.split(separator: " ").map(String.init)
        switch p[0] {
        case "H":
            peerName = p.dropFirst().joined(separator: " ")
            refresh()
        case "F":
            onMac = p.count > 1 && p[1] == "1"
            if !onMac { releaseAll() }
            refresh()
        case "U":
            let units = p.dropFirst().compactMap { UInt16($0, radix: 16) }
            typeUnicode(units)
        case "K" where p.count >= 5:
            guard let vk = Int(p[1]), let mods = Int(p[3]) else { return }
            key(vk: vk, isDown: p[2] == "1", mods: mods, ext: p[4] == "1")
        case "R":
            releaseAll()
        default:
            break
        }
    }

    func send(_ s: String) {
        guard let c = conn else { return }
        c.send(content: (s + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - wpisywanie

    func post(_ code: CGKeyCode, isDown: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Znaki z układu Windowsa (np. polski programisty: AltGr+a = ą) wpisane jako Unicode.
    func typeUnicode(_ units: [UInt16]) {
        guard !units.isEmpty else { return }
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            e.flags = []
            units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            e.post(tap: .cghidEventTap)
        }
    }

    /// Klawisz z Windowsa jako klawisz Maca. Skróty jak na Macu: Ctrl -> Cmd, Alt -> Option,
    /// Win -> Control; Home/End -> Cmd+←/→, Ctrl+strzałka i Ctrl+Backspace -> po słowie (Option).
    func key(vk: Int, isDown: Bool, mods: Int, ext: Bool) {
        let id = vk | (ext ? 0x10000 : 0)
        if !isDown {
            if let d = down.removeValue(forKey: id) { post(d.code, isDown: false, flags: d.flags) }
            return
        }
        let shift = mods & 1 != 0, ctrl = mods & 2 != 0, alt = mods & 4 != 0, win = mods & 8 != 0
        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if ctrl { flags.insert(.maskCommand) }
        if alt { flags.insert(.maskAlternate) }
        if win { flags.insert(.maskControl) }

        guard var code = macKey[vk] else { return }            // nieznany klawisz: pomiń
        if vk == 0x24 || vk == 0x23 {                          // Home / End
            if ctrl { code = vk == 0x24 ? kUp : kDown }       // Ctrl+Home/End = początek/koniec dokumentu
            else { code = vk == 0x24 ? kLeft : kRight }        // Home/End = początek/koniec linii
            flags.insert(.maskCommand)
        } else if ctrl && [0x25, 0x26, 0x27, 0x28, 0x08, 0x2E].contains(vk) {
            // Ctrl+strzałka = skok o słowo/akapit, Ctrl+Backspace/Delete = całe słowo
            flags.remove(.maskCommand)
            flags.insert(.maskAlternate)
        }
        // strzałki i klawisze funkcyjne Mac oznacza flagami, bez nich część aplikacji ich nie łapie
        if [kLeft, kRight, kUp, kDown].contains(code) { flags.insert([.maskNumericPad, .maskSecondaryFn]) }
        down[id] = (code, flags)
        post(code, isDown: true, flags: flags)
    }

    func releaseAll() {
        for d in down.values { post(d.code, isDown: false, flags: []) }
        down.removeAll()
    }

    // MARK: - mysz Maca

    func ensureTap() {
        // wpisywanie klawiszy (CGEvent.post) wymaga uprawnienia Dostępność
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { refresh(); return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        let cb: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated { app.mouse(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        // tylko nasłuch: mysz Maca działa normalnie, my tylko patrzymy, czy się rusza
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: cb, userInfo: nil) else { refresh(); return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        refresh()
    }

    func mouse(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard !onMac, conn != nil else { return }
            let now = Date()
            if now.timeIntervalSince(lastMove) > 0.4 { moveAcc = 0 }
            lastMove = now
            moveAcc += abs(event.getDoubleValueField(.mouseEventDeltaX)) + abs(event.getDoubleValueField(.mouseEventDeltaY))
            if moveAcc > macMoveThreshold { requestKeyboard() }
        case .scrollWheel:
            // bezwładność przewijania po puszczeniu palców nie przełącza
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 { requestKeyboard() }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            requestKeyboard()
        default:
            break
        }
    }

    /// Prosi Windowsa o klawiaturę; Windows potwierdza "F 1".
    func requestKeyboard() {
        guard !onMac, conn != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRequest) > 0.15 else { return }
        lastRequest = now
        moveAcc = 0
        send("M")
    }
}

let app = App()
let nsapp = NSApplication.shared
nsapp.delegate = app
nsapp.setActivationPolicy(.accessory)
nsapp.run()

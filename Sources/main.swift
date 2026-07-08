import AppKit
import AVFoundation
import ApplicationServices

// WisprLite — push-to-talk local dictation.
// Hold a bound modifier to record, release to transcribe (whisper.cpp) and paste.
// Two bindings: plain dictate, and dictate+Enter (presses Return after pasting).

let MODEL_PATH = (Bundle.main.bundlePath as NSString)
    .deletingLastPathComponent + "/models/ggml-large-v3-turbo.bin"
let WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"

let LOG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("WisprLite/wispr.log")
func logf(_ s: String) {
    let line = s + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: LOG_URL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: LOG_URL)
    }
}

// ---- Modifier chords usable for push-to-talk (holdable, no character typed) ----
// A chord = a set of held modifiers (left/right agnostic, like normal macOS hotkeys).
struct Mods: OptionSet {
    let rawValue: Int
    static let ctrl  = Mods(rawValue: 1 << 0)
    static let opt   = Mods(rawValue: 1 << 1)
    static let shift = Mods(rawValue: 1 << 2)
    static let cmd   = Mods(rawValue: 1 << 3)
    static let fn    = Mods(rawValue: 1 << 4)

    init(rawValue: Int) { self.rawValue = rawValue }
    init(flags: CGEventFlags) {
        var m = Mods()
        if flags.contains(.maskControl)      { m.insert(.ctrl) }
        if flags.contains(.maskAlternate)    { m.insert(.opt) }
        if flags.contains(.maskShift)        { m.insert(.shift) }
        if flags.contains(.maskCommand)      { m.insert(.cmd) }
        if flags.contains(.maskSecondaryFn)  { m.insert(.fn) }
        self = m
    }
    var name: String {
        var s = ""
        if contains(.ctrl)  { s += "⌃" }
        if contains(.opt)   { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.cmd)   { s += "⌘" }
        if contains(.fn)    { s += "fn" }
        return s.isEmpty ? "—" : s
    }
}

// Legacy single-modifier keycodes → chord, for migrating old configs.
func chord(fromLegacyKeyCode k: UInt16) -> Int {
    switch k {
    case 54, 55: return Mods.cmd.rawValue
    case 58, 61: return Mods.opt.rawValue
    case 59, 62: return Mods.ctrl.rawValue
    case 56, 60: return Mods.shift.rawValue
    case 63:     return Mods.fn.rawValue
    default:     return 0
    }
}

// ---- Config persisted to ~/.wisprlite/config.json ----
struct Config: Codable {
    // Each chord is a Mods rawValue (a set of modifiers held together).
    var dictateChords: [Int] = [Mods.opt.rawValue]        // ⌥
    var dictateEnterChords: [Int] = [Mods.cmd.rawValue]   // ⌘

    enum CodingKeys: String, CodingKey {
        case dictateChords, dictateEnterChords, dictateKeys, dictateEnterKeys  // last two = legacy
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let a = try? c.decode([Int].self, forKey: .dictateChords) { dictateChords = a }
        else if let ks = try? c.decode([UInt16].self, forKey: .dictateKeys) {
            dictateChords = ks.map(chord(fromLegacyKeyCode:)).filter { $0 != 0 }
        }
        if let a = try? c.decode([Int].self, forKey: .dictateEnterChords) { dictateEnterChords = a }
        else if let ks = try? c.decode([UInt16].self, forKey: .dictateEnterKeys) {
            dictateEnterChords = ks.map(chord(fromLegacyKeyCode:)).filter { $0 != 0 }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dictateChords, forKey: .dictateChords)
        try c.encode(dictateEnterChords, forKey: .dictateEnterChords)
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".wisprlite/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return cfg
    }
    func save() {
        try? FileManager.default.createDirectory(
            at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Config.url)
    }
}

final class Recorder {
    private var recorder: AVAudioRecorder?
    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("wispr_rec.wav")

    func start() {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            recorder = try AVAudioRecorder(url: wavURL, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
        } catch { NSLog("record start failed: \(error)") }
    }
    func stop() -> URL? {
        guard let r = recorder, r.isRecording else { return nil }
        r.stop(); recorder = nil
        return wavURL
    }
    /// Current mic loudness, normalized 0…1.
    func level() -> CGFloat {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)   // -160…0 dB
        return CGFloat(max(0, min(1, (db + 50) / 50)))
    }
}

extension Data { mutating func appendStr(_ s: String) { if let d = s.data(using: .utf8) { append(d) } } }

// Keeps the 3.1GB model resident in whisper-server so it loads ONCE, not per dictation.
// Model load is ~2.2s; inference is ~0.2s — so persistent server ≈ 10x faster per utterance.
final class WhisperServer {
    private var proc: Process?
    static let endpoint = URL(string: "http://127.0.0.1:8080/inference")!

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-server")
        p.arguments = ["-m", MODEL_PATH, "--host", "127.0.0.1", "--port", "8080", "-l", "auto"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proc = p; logf("whisper-server starting (loading model once)") }
        catch { logf("whisper-server failed to start: \(error)") }
    }
    func stop() { proc?.terminate() }
}

final class Transcriber {
    // Fast path: POST audio to the always-loaded server. Falls back to a one-shot CLI run.
    func transcribe(_ wav: URL) -> String {
        let viaServer = serverTranscribe(wav)
        return viaServer.isEmpty ? cliTranscribe(wav) : viaServer
    }

    private func serverTranscribe(_ wav: URL) -> String {
        guard let audio = try? Data(contentsOf: wav) else { return "" }
        let boundary = "WisprLiteBoundary7MA4YWxkTrZu0gW"
        var body = Data()
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n")
        body.appendStr("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendStr("\r\n--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n")
        body.appendStr("--\(boundary)\r\n")
        // Force Polish — auto-detect drifts to French/English on short clips.
        body.appendStr("Content-Disposition: form-data; name=\"language\"\r\n\r\npl\r\n")
        body.appendStr("--\(boundary)--\r\n")

        var req = URLRequest(url: WhisperServer.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var result = ""
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) {
                result = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private func cliTranscribe(_ wav: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: WHISPER_CLI)
        p.arguments = ["-m", MODEL_PATH, "-f", wav.path, "-l", "pl", "-nt", "-np"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() }
        catch { logf("whisper cli failed: \(error)"); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class Paster {
    private func postKey(_ vk: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
    func paste(_ text: String, pressEnter: Bool) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(0x09, flags: .maskCommand)  // Cmd+V
        if pressEnter {
            usleep(30_000)                   // let paste land before Return
            postKey(0x24)                    // Return
        }
    }
}

// ---- Floating waveform pill overlay ----
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

final class PillView: NSView {
    var open: CGFloat = 0            // animated 0 (idle) … 1 (active)
    var targetOpen: CGFloat = 0
    var level: CGFloat = 0           // smoothed mic level 0…1
    var levelProvider: (() -> CGFloat)?
    private var phase: CGFloat = 0
    private let bars = 18

    private let idleW: CGFloat = 46,  idleH: CGFloat = 9
    private let activeW: CGFloat = 190, activeH: CGFloat = 54

    override var isFlipped: Bool { false }

    func tick() {
        open += (targetOpen - open) * 0.22
        let raw = (targetOpen > 0.5 ? (levelProvider?() ?? 0) : 0)
        level += (raw - level) * 0.35          // smooth
        phase += 0.5
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let a = max(0, min(1, open))
        let w = lerp(idleW, activeW, a)
        let h = lerp(idleH, activeH, a)
        let cx = bounds.midX, cy = bounds.midY
        let pill = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
        let radius = h / 2

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2),
                      blur: 14 * a,
                      color: NSColor.black.withAlphaComponent(0.4 * a).cgColor)
        NSColor(white: 0.09, alpha: lerp(0.30, 0.97, a)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        ctx.restoreGState()

        let barsAlpha = max(0, (a - 0.2) / 0.8)
        guard barsAlpha > 0 else { return }

        let padX: CGFloat = 22, padY: CGFloat = 12
        let area = w - padX * 2
        let slot = area / CGFloat(bars)
        let barW = slot * 0.42
        let maxH = h - padY * 2
        let minH = barW                      // dot when silent
        let mid = CGFloat(bars - 1) / 2

        for i in 0..<bars {
            // symmetric center bump (tall middle, short edges) like a real meter
            let centerWeight = pow(cos((CGFloat(i) - mid) / mid * .pi / 2), 1.3)
            let wave = 0.55 + 0.45 * sin(phase * 0.25 + CGFloat(i) * 0.7)
            let energy = level * centerWeight * wave
            let bh = max(minH, minH + energy * (maxH - minH))
            let x = pill.minX + padX + slot * CGFloat(i) + (slot - barW) / 2
            let r = CGRect(x: x, y: cy - bh/2, width: barW, height: bh)
            NSColor.white.withAlphaComponent(barsAlpha * (0.55 + 0.45 * centerWeight)).setFill()
            NSBezierPath(roundedRect: r, xRadius: barW/2, yRadius: barW/2).fill()
        }
    }
}

final class PillOverlay {
    private let window: NSWindow
    private let view = PillView()
    private var timer: Timer?

    init(levelProvider: @escaping () -> CGFloat) {
        let size = NSSize(width: 260, height: 90)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        view.levelProvider = levelProvider
        window.contentView = view
        reposition()
        window.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.view.tick()
        }
    }

    func reposition() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let s = window.frame.size
        window.setFrameOrigin(NSPoint(x: f.midX - s.width/2, y: f.minY + 34))
    }

    func setActive(_ active: Bool) {
        reposition()
        DispatchQueue.main.async { self.view.targetOpen = active ? 1 : 0 }
    }
}

enum Capturing { case none, dictate, dictateEnter }

// ---- Settings window ----
final class SettingsWindowController: NSWindowController {
    weak var app: AppDelegate?
    private let dictateChips = NSStackView()
    private let enterChips = NSStackView()
    private let dictateAddBtn = NSButton(title: "＋ Add key", target: nil, action: nil)
    private let enterAddBtn = NSButton(title: "＋ Add key", target: nil, action: nil)

    static func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        return l
    }

    convenience init(app: AppDelegate) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "WisprLite Settings"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        self.app = app

        let title = NSTextField(labelWithString: "Hotkeys")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        for cs in [dictateChips, enterChips] {
            cs.orientation = .horizontal; cs.spacing = 8; cs.alignment = .centerY
        }
        dictateAddBtn.target = self; dictateAddBtn.action = #selector(recordDictate)
        enterAddBtn.target = self; enterAddBtn.action = #selector(recordEnter)
        dictateAddBtn.bezelStyle = .rounded; enterAddBtn.bezelStyle = .rounded
        dictateAddBtn.title = "＋ Add combo"; enterAddBtn.title = "＋ Add combo"

        let grid = NSGridView(views: [
            [SettingsWindowController.caption("Dictate"), dictateChips],
            [SettingsWindowController.caption("Dictate + Enter"), enterChips],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 1).yPlacement = .center

        let hint = NSTextField(wrappingLabelWithString:
            "Add one or more modifier combos (⌥, ⌘⇧, ⌃⌥, Fn…) per mode — any of them starts dictation. "
            + "Click “Add combo”, then press & hold the combination, then release. Click a combo to remove it. "
            + "“Dictate + Enter” also presses Return after pasting.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 432),
        ])
        win.center()
        refresh()
    }

    private func chip(_ raw: Int, section: Capturing) -> NSButton {
        let b = NSButton(title: "\(Mods(rawValue: raw).name)  ✕", target: self, action: #selector(removeKey(_:)))
        b.bezelStyle = .rounded
        b.tag = (section == .dictate ? 100000 : 200000) + raw
        return b
    }

    func refresh() {
        let capturing = app?.capturing ?? .none
        for v in dictateChips.arrangedSubviews { dictateChips.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in enterChips.arrangedSubviews { enterChips.removeArrangedSubview(v); v.removeFromSuperview() }

        for raw in app?.cfg.dictateChords ?? [] { dictateChips.addArrangedSubview(chip(raw, section: .dictate)) }
        dictateAddBtn.title = capturing == .dictate ? "Press a combo…" : "＋ Add combo"
        dictateAddBtn.isEnabled = capturing == .none || capturing == .dictate
        dictateChips.addArrangedSubview(dictateAddBtn)

        for raw in app?.cfg.dictateEnterChords ?? [] { enterChips.addArrangedSubview(chip(raw, section: .dictateEnter)) }
        enterAddBtn.title = capturing == .dictateEnter ? "Press a combo…" : "＋ Add combo"
        enterAddBtn.isEnabled = capturing == .none || capturing == .dictateEnter
        enterChips.addArrangedSubview(enterAddBtn)
    }

    @objc func removeKey(_ sender: NSButton) {
        guard let app else { return }
        let isDictate = sender.tag < 200000
        let raw = sender.tag % 100000
        if isDictate { app.cfg.dictateChords.removeAll { $0 == raw } }
        else { app.cfg.dictateEnterChords.removeAll { $0 == raw } }
        app.cfg.save(); app.buildMenu(); refresh()
    }

    @objc func recordDictate() { app?.startCapture(.dictate) }
    @objc func recordEnter() { app?.startCapture(.dictateEnter) }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let recorder = Recorder()
    let transcriber = Transcriber()
    let paster = Paster()
    let whisper = WhisperServer()
    var eventTap: CFMachPort?
    var cfg = Config.load()
    var isRecording = false
    var pendingEnter = false
    var activeChord: Mods?
    var captureMask: Mods = []
    var capturing: Capturing = .none
    var settingsWC: SettingsWindowController?
    var overlay: PillOverlay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setIcon("🎙️")
        buildMenu()
        overlay = PillOverlay(levelProvider: { [weak self] in self?.recorder.level() ?? 0 })
        whisper.start()          // load model once, keep it resident (fast dictation)
        checkPermissions()
        installEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) { whisper.stop() }

    // Check permissions first; only prompt for the ones actually missing.
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }   // ask once
        case .denied, .restricted:
            logf("mic permission missing — enable WisprLite in Privacy → Microphone")
        default:
            break                                                  // already granted → no prompt
        }

        if AXIsProcessTrusted() {
            logf("accessibility already granted")
        } else {
            logf("accessibility missing — prompting once")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)                // system prompt shows only when untrusted
        }
    }

    // CGEventTap: global keyboard listen gated by Accessibility only — no Input Monitoring
    // permission needed (same approach dictation apps like Wispr Flow use). Sees every app
    // and our own windows, so it also drives key-capture in Settings.
    func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .flagsChanged {
                me.process(Mods(flags: event.flags))
            }
            return Unmanaged.passUnretained(event)
        }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: cb, userInfo: ptr)
        else {
            logf("EVENT TAP FAILED — grant Accessibility to WisprLite")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logf("event tap installed OK")
    }

    func process(_ mods: Mods) {
        // Capture mode: assemble the held combo, commit it when the user releases everything.
        if capturing != .none {
            captureMask.formUnion(mods)
            guard mods.isEmpty, !captureMask.isEmpty else { return }
            let raw = captureMask.rawValue
            if capturing == .dictate {
                if !cfg.dictateChords.contains(raw) { cfg.dictateChords.append(raw) }
            } else {
                if !cfg.dictateEnterChords.contains(raw) { cfg.dictateEnterChords.append(raw) }
            }
            cfg.save()
            captureMask = []
            capturing = .none
            DispatchQueue.main.async { self.buildMenu(); self.settingsWC?.refresh() }
            return
        }

        if !isRecording {
            guard !mods.isEmpty else { return }
            let raw = mods.rawValue
            let isEnter = cfg.dictateEnterChords.contains(raw)
            let isDictate = cfg.dictateChords.contains(raw)
            if isEnter || isDictate { beginRecording(enter: isEnter, chord: mods) }
        } else if mods != activeChord {
            endRecording()          // combo changed/released → stop
        }
    }

    func beginRecording(enter: Bool, chord: Mods) {
        guard !isRecording else { return }
        isRecording = true
        pendingEnter = enter
        activeChord = chord
        setIcon(enter ? "🔴↵" : "🔴")
        overlay?.setActive(true)
        recorder.start()
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        activeChord = nil
        let enter = pendingEnter
        overlay?.setActive(false)
        setIcon("⏳")
        guard let wav = recorder.stop() else { setIcon("🎙️"); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.transcriber.transcribe(wav)
            DispatchQueue.main.async {
                logf("TRANSCRIPT len=\(text.count) trusted=\(AXIsProcessTrusted()) text='\(text.prefix(80))'")
                self.paster.paste(text, pressEnter: enter)
                self.setIcon("🎙️")
            }
        }
    }

    func setIcon(_ s: String) { DispatchQueue.main.async { self.statusItem.button?.title = s } }

    func buildMenu() {
        let menu = NSMenu()
        let names = { (cs: [Int]) in cs.isEmpty ? "—" : cs.map { Mods(rawValue: $0).name }.joined(separator: ", ") }
        menu.addItem(withTitle: "Dictate:  \(names(cfg.dictateChords))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Dictate + Enter:  \(names(cfg.dictateEnterChords))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let s = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(.separator())
        let q = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        statusItem.menu = menu
    }

    func startCapture(_ what: Capturing) {
        capturing = what
        captureMask = []
        buildMenu()
        settingsWC?.refresh()
    }

    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(app: self) }
        settingsWC?.refresh()
        settingsWC?.show()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

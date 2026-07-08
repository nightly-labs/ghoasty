import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio

// WisprLite — push-to-talk local dictation.
// Hold a bound modifier to record, release to transcribe (whisper.cpp) and paste.
// Two bindings: plain dictate, and dictate+Enter (presses Return after pasting).

let ROOT_DIR = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
let MODELS_DIR = ROOT_DIR + "/models"
func modelPath(_ file: String) -> String { MODELS_DIR + "/" + file }

// Parakeet v3 (parakeet.cpp): ~0.1s/utterance, multilingual auto-detect, auto punctuation.
let PARAKEET_SERVER_BIN = ROOT_DIR + "/parakeet.cpp/build/examples/server/parakeet-server"
let PARAKEET_MODEL = modelPath("parakeet-tdt-0.6b-v3-f16.gguf")

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
    // Allowed transcription languages. 1 → forced; >1 → auto limited to these; empty → full auto.
    var languages: [String] = ["pl"]
    // Initial prompt biases whisper toward your domain terms / names. Editable here.
    var prompt: String = "Transkrypcja po polsku. Programowanie, API, frontend, backend, deploy, commit, TypeScript, Rust, Solana."
    // Preferred input device UID. nil → built-in mic (keeps Bluetooth output in A2DP).
    var inputDeviceUID: String? = nil
    // Overlay: "full" (waveform + WPM) or "minimal" (voice indicator only).
    var pillStyle: String = "full"
    // Animation lerp rates (per frame): higher = snappier. Separate for appear / hide.
    var animAppear: Double = 0.30
    var animHide: Double = 0.30
    // Seconds the pill lingers after the key is released before it fades out.
    var holdDuration: Double = 1.5

    enum CodingKeys: String, CodingKey {
        case dictateChords, dictateEnterChords, inputDeviceUID
        case pillStyle, animAppear, animHide, holdDuration
        case dictateKeys, dictateEnterKeys  // legacy
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
        if let u = try? c.decode(String?.self, forKey: .inputDeviceUID) { inputDeviceUID = u }
        if let s = try? c.decode(String.self, forKey: .pillStyle) { pillStyle = s }
        if let x = try? c.decode(Double.self, forKey: .animAppear) { animAppear = x }
        if let x = try? c.decode(Double.self, forKey: .animHide) { animHide = x }
        if let x = try? c.decode(Double.self, forKey: .holdDuration) { holdDuration = x }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dictateChords, forKey: .dictateChords)
        try c.encode(dictateEnterChords, forKey: .dictateEnterChords)
        try c.encode(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(pillStyle, forKey: .pillStyle)
        try c.encode(animAppear, forKey: .animAppear)
        try c.encode(animHide, forKey: .animHide)
        try c.encode(holdDuration, forKey: .holdDuration)
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

// ---- Core Audio device helpers ----
func allAudioDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
    else { return [] }
    return devices
}

func deviceHasInput(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size)
    return size > 0
}

func deviceTransport(_ dev: AudioDeviceID) -> UInt32 {
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t)
    return t
}

func deviceStringProp(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var str: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &str) {
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? (str as String?) : nil
}
func deviceUID(_ dev: AudioDeviceID) -> String? { deviceStringProp(dev, kAudioDevicePropertyDeviceUID) }
func deviceName(_ dev: AudioDeviceID) -> String { deviceStringProp(dev, kAudioObjectPropertyName) ?? "Unknown" }

// Built-in mic — default so we never open the Bluetooth headset's mic (which would force
// AirPods from high-quality A2DP playback into low-quality HFP call mode).
func builtInInputDeviceID() -> AudioDeviceID? {
    allAudioDevices().first { deviceHasInput($0) && deviceTransport($0) == kAudioDeviceTransportTypeBuiltIn }
}
func inputDeviceList() -> [(uid: String, name: String)] {
    allAudioDevices().filter(deviceHasInput).compactMap { d in deviceUID(d).map { (uid: $0, name: deviceName(d)) } }
}
func deviceID(forUID uid: String) -> AudioDeviceID? {
    allAudioDevices().first { deviceUID($0) == uid }
}

final class Recorder {
    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("wispr_rec.wav")
    var deviceUID: String?          // nil → built-in mic
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writeFormat: AVAudioFormat?   // = file.processingFormat (what write() expects)
    private var curLevel: CGFloat = 0
    private var running = false

    // On-disk WAV: 16 kHz mono PCM16 — what whisper wants.
    private let fileSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    func start() {
        let input = engine.inputNode
        // Chosen device, else built-in mic (keeps Bluetooth output in A2DP).
        let devID = deviceUID.flatMap(deviceID(forUID:)) ?? builtInInputDeviceID()
        if let dev = devID, let unit = input.audioUnit {
            var d = dev
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        } else {
            logf("no capture device resolved — using default input")
        }

        let inFormat = input.inputFormat(forBus: 0)
        logf("recording @ \(Int(inFormat.sampleRate))Hz (built-in mic: \(builtInInputDeviceID() != nil))")
        guard inFormat.sampleRate > 0 else { logf("no input format"); return }
        guard let f = try? AVAudioFile(forWriting: wavURL, settings: fileSettings) else {
            logf("could not open output file"); return
        }
        file = f
        // write() requires buffers in the file's processingFormat — convert to THAT, not a
        // custom int16 format (mismatch there aborts inside AVAudioFile.write).
        writeFormat = f.processingFormat
        converter = AVAudioConverter(from: inFormat, to: f.processingFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf)
        }
        engine.prepare()
        do { try engine.start(); running = true }
        catch { logf("engine start failed: \(error)") }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            let db = 20 * log10f(max(rms, 1e-7))
            curLevel = CGFloat(max(0, min(1, (db + 50) / 50)))
        }
        guard let converter, let file, let wf = writeFormat else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * wf.sampleRate / buffer.format.sampleRate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: wf, frameCapacity: cap) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if outBuf.frameLength > 0 { try? file.write(from: outBuf) }
    }

    func stop() -> URL? {
        guard running else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil; converter = nil; writeFormat = nil; running = false; curLevel = 0
        return wavURL
    }
    func level() -> CGFloat { running ? curLevel : 0 }
}

extension Data { mutating func appendStr(_ s: String) { if let d = s.data(using: .utf8) { append(d) } } }

// Keeps the Parakeet model resident in parakeet-server (OpenAI-compatible) on port 8090.
final class ParakeetServer {
    private var proc: Process?

    func start() {
        guard FileManager.default.fileExists(atPath: PARAKEET_SERVER_BIN) else {
            logf("parakeet-server missing — run build.sh"); return
        }
        let p = Process()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.executableURL = URL(fileURLWithPath: PARAKEET_SERVER_BIN)
        p.arguments = ["--model", PARAKEET_MODEL, "--host", "127.0.0.1", "--port", "8090"]
        do { try p.run(); proc = p; logf("parakeet-server starting") }
        catch { logf("parakeet-server failed to start: \(error)") }
    }

    func stop() { proc?.terminate(); proc?.waitUntilExit(); proc = nil }
}

final class Transcriber {
    static let endpoint = URL(string: "http://127.0.0.1:8090/v1/audio/transcriptions")!

    // Parakeet is multilingual with built-in language auto-detect + punctuation.
    func transcribe(_ wav: URL) -> String {
        guard let audio = try? Data(contentsOf: wav) else { return "" }
        let boundary = "WisprLiteBoundary7MA4YWxkTrZu0gW"
        var body = Data()
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n")
        body.appendStr("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendStr("\r\n--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext")
        body.appendStr("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: Transcriber.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var result = ""
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            if let data, let s = String(data: data, encoding: .utf8) {
                result = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.resume()
        sem.wait()
        return result
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

// Polish plural for "słowo".
func plWords(_ n: Int) -> String {
    if n == 1 { return "słowo" }
    let t = n % 10, h = n % 100
    return (2...4).contains(t) && !(12...14).contains(h) ? "słowa" : "słów"
}

final class PillView: NSView {
    var level: CGFloat = 0           // smoothed mic level 0…1
    var levelProvider: (() -> CGFloat)?
    private var phase: CGFloat = 0
    private let bars = 18
    private let pillCenterY: CGFloat = 55

    private let activeW: CGFloat = 190, activeH: CGFloat = 54
    private let statsW: CGFloat = 66

    var minimal = false                 // voice indicator only (no WPM/timer panel)
    var appearRate: CGFloat = 0.30      // fade-in speed
    var hideRate: CGFloat = 0.30        // fade-out speed
    var holdDuration: Double = 1.5      // seconds the pill lingers after release

    // presence drives scale + opacity of the WHOLE pill as one unit (fade in / fade out).
    private var presence: CGFloat = 0
    private var presenceTarget: CGFloat = 0
    private var wpmDisplay: CGFloat = 0     // animated count-up
    private var wpmTarget: CGFloat = 0
    private var statsToken = 0              // invalidates stale hide timers

    // Panel shows a live timer while recording, then the final WPM.
    private enum StatMode { case timer, wpm }
    private var mode: StatMode = .timer
    private var recStart: Date?
    private var frozenElapsed: TimeInterval = 0

    override var isFlipped: Bool { false }

    func tick() {
        let rate = presenceTarget > presence ? appearRate : hideRate
        presence += (presenceTarget - presence) * rate
        wpmDisplay += (wpmTarget - wpmDisplay) * 0.28
        let raw = (recStart != nil ? (levelProvider?() ?? 0) : 0)
        level += (raw - level) * 0.35          // smooth
        phase += 0.5
        needsDisplay = true
    }

    // Recording started — fade the pill in, panel shows a live timer immediately.
    func setRecording() {
        statsToken += 1
        presenceTarget = 1
        mode = .timer
        recStart = Date()
        wpmTarget = 0; wpmDisplay = 0
    }

    // Recording ended: freeze the timer until stats arrive.
    func stopTimer() {
        if let rs = recStart { frozenElapsed = Date().timeIntervalSince(rs) }
        recStart = nil
    }

    // Fade the whole pill out now (cancels pending hide timers).
    func shrink() {
        statsToken += 1
        presenceTarget = 0
        recStart = nil
    }

    // Linger for holdDuration, then fade the whole pill out.
    private func scheduleHide() {
        statsToken += 1
        let t = statsToken
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, holdDuration)) { [weak self] in
            guard let self, self.statsToken == t else { return }
            self.presenceTarget = 0          // whole pill fades together
        }
    }

    // Keep showing (e.g. minimal mode) for holdDuration, then fade out.
    func holdThenHide() { recStart = nil; scheduleHide() }

    // Swap the live timer for the final WPM (count up), hold, then fade the whole pill out.
    func showStats(wpm: Int) {
        mode = .wpm
        recStart = nil
        wpmTarget = CGFloat(wpm)
        wpmDisplay = 0
        scheduleHide()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = max(0, min(1, presence))
        guard p > 0.003 else { return }
        let e = p * p * (3 - 2 * p)             // smoothstep
        let scale = lerp(0.62, 1, e)            // whole pill shrinks toward its centre

        let cy = pillCenterY
        let h = activeH
        let panelW = minimal ? 0 : statsW       // minimal → voice indicator only
        let leftX = bounds.midX - activeW / 2   // waveform region is screen-centered
        let divX = leftX + activeW
        let pill = CGRect(x: leftX, y: cy - h / 2, width: activeW + panelW, height: h)
        let anchorX = pill.midX

        ctx.saveGState()
        ctx.translateBy(x: anchorX, y: cy)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -anchorX, y: -cy)

        // pill background
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 14 * p,
                      color: NSColor.black.withAlphaComponent(0.4 * p).cgColor)
        NSColor(white: 0.09, alpha: 0.97 * p).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // waveform (left region)
        let padX: CGFloat = 22, padY: CGFloat = 12
        let area = activeW - padX * 2
        let slot = area / CGFloat(bars)
        let barW = slot * 0.42
        let maxH = h - padY * 2
        let minH = barW
        let mid = CGFloat(bars - 1) / 2
        for i in 0..<bars {
            let centerWeight = pow(cos((CGFloat(i) - mid) / mid * .pi / 2), 1.3)
            let wave = 0.55 + 0.45 * sin(phase * 0.25 + CGFloat(i) * 0.7)
            let energy = level * centerWeight * wave
            let bh = max(minH, minH + energy * (maxH - minH))
            let x = leftX + padX + slot * CGFloat(i) + (slot - barW) / 2
            NSColor.white.withAlphaComponent(p * (0.55 + 0.45 * centerWeight)).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: cy - bh / 2, width: barW, height: bh),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }

        // divider + stats (right region) — skipped entirely in minimal mode
        guard !minimal else { ctx.restoreGState(); return }
        NSColor.white.withAlphaComponent(0.14 * p).setFill()
        NSBezierPath(rect: CGRect(x: divX - 0.5, y: cy - h / 2 + 9, width: 1, height: h - 18)).fill()

        let numText: String, labelText: String
        switch mode {
        case .timer:
            let el = recStart.map { Date().timeIntervalSince($0) } ?? frozenElapsed
            numText = String(format: "%.1f", el); labelText = "sec"
        case .wpm:
            numText = "\(Int(wpmDisplay.rounded()))"; labelText = "wpm"
        }
        let numStr = NSAttributedString(string: numText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(p)])
        let lblStr = NSAttributedString(string: labelText, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5 * p)])
        let ns = numStr.size(), ls = lblStr.size()
        let cxs = divX + statsW / 2
        let blockH = ns.height + ls.height
        let lblY = cy - blockH / 2
        numStr.draw(at: NSPoint(x: cxs - ns.width / 2, y: lblY + ls.height))
        lblStr.draw(at: NSPoint(x: cxs - ls.width / 2, y: lblY))

        ctx.restoreGState()
    }
}

final class PillOverlay {
    private let window: NSWindow
    private let view = PillView()
    private var timer: Timer?

    init(levelProvider: @escaping () -> CGFloat) {
        let size = NSSize(width: 340, height: 110)
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
        window.setFrameOrigin(NSPoint(x: f.midX - s.width/2, y: f.minY + 24))
    }

    func setActive(_ active: Bool) {
        reposition()
        DispatchQueue.main.async { active ? self.view.setRecording() : self.view.shrink() }
    }

    func stopTimer() {
        DispatchQueue.main.async { self.view.stopTimer() }
    }

    func showStats(wpm: Int) {
        DispatchQueue.main.async { self.view.showStats(wpm: wpm) }
    }

    func holdThenHide() {
        DispatchQueue.main.async { self.view.holdThenHide() }
    }

    func configure(minimal: Bool, appear: Double, hide: Double, hold: Double) {
        DispatchQueue.main.async {
            self.view.minimal = minimal
            self.view.appearRate = CGFloat(appear)
            self.view.hideRate = CGFloat(hide)
            self.view.holdDuration = hold
        }
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
    private let micPopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    private let appearSlider = NSSlider()
    private let hideSlider = NSSlider()
    private let holdSlider = NSSlider()

    static func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        return l
    }

    convenience init(app: AppDelegate) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
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
        micPopup.target = self; micPopup.action = #selector(pickMic)
        stylePopup.target = self; stylePopup.action = #selector(pickStyle)
        for sl in [appearSlider, hideSlider] {
            sl.minValue = 0.10; sl.maxValue = 0.55   // slow → fast (lerp rate)
            sl.target = self; sl.action = #selector(changeAnim)
            sl.controlSize = .small
            sl.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        holdSlider.minValue = 0.0; holdSlider.maxValue = 4.0   // seconds after release
        holdSlider.target = self; holdSlider.action = #selector(changeAnim)
        holdSlider.controlSize = .small
        holdSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let grid = NSGridView(views: [
            [SettingsWindowController.caption("Dictate"), dictateChips],
            [SettingsWindowController.caption("Dictate + Enter"), enterChips],
            [SettingsWindowController.caption("Microphone"), micPopup],
            [SettingsWindowController.caption("Overlay"), stylePopup],
            [SettingsWindowController.caption("Appear speed"), appearSlider],
            [SettingsWindowController.caption("Hide speed"), hideSlider],
            [SettingsWindowController.caption("Show after release"), holdSlider],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        for i in 0..<7 { grid.row(at: i).yPlacement = .center }

        let hint = NSTextField(wrappingLabelWithString:
            "Hotkeys: add modifier combos (⌥, ⌘⇧, ⌃⌥, Fn…) — any starts dictation; “Dictate + Enter” also presses Return. "
            + "Parakeet auto-detects the language and adds punctuation. "
            + "Microphone: built-in keeps Bluetooth output in high quality. Click a chip to remove it.")
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

        stylePopup.removeAllItems()
        stylePopup.addItem(withTitle: "Full — waveform + words/min")
        stylePopup.lastItem?.representedObject = "full"
        stylePopup.addItem(withTitle: "Minimal — voice indicator only")
        stylePopup.lastItem?.representedObject = "minimal"
        stylePopup.selectItem(at: app?.cfg.pillStyle == "minimal" ? 1 : 0)
        appearSlider.doubleValue = app?.cfg.animAppear ?? 0.30
        hideSlider.doubleValue = app?.cfg.animHide ?? 0.30
        holdSlider.doubleValue = app?.cfg.holdDuration ?? 1.5

        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "Built-in mic (recommended)")
        micPopup.lastItem?.representedObject = nil
        let devices = inputDeviceList()
        for d in devices {
            micPopup.addItem(withTitle: d.name)
            micPopup.lastItem?.representedObject = d.uid
        }
        if let uid = app?.cfg.inputDeviceUID, let idx = devices.firstIndex(where: { $0.uid == uid }) {
            micPopup.selectItem(at: idx + 1)
        } else {
            micPopup.selectItem(at: 0)
        }
    }

    @objc func pickMic(_ sender: NSPopUpButton) {
        guard let app else { return }
        let uid = sender.selectedItem?.representedObject as? String
        app.cfg.inputDeviceUID = uid
        app.cfg.save()
        app.recorder.deviceUID = uid
    }

    @objc func pickStyle(_ sender: NSPopUpButton) {
        guard let app, let s = sender.selectedItem?.representedObject as? String else { return }
        app.cfg.pillStyle = s
        app.cfg.save(); app.applyOverlayConfig(); app.buildMenu()
    }

    @objc func changeAnim(_ sender: NSSlider) {
        guard let app else { return }
        app.cfg.animAppear = appearSlider.doubleValue
        app.cfg.animHide = hideSlider.doubleValue
        app.cfg.holdDuration = holdSlider.doubleValue
        app.cfg.save(); app.applyOverlayConfig()
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
    let parakeet = ParakeetServer()
    var eventTap: CFMachPort?
    var cfg = Config.load()
    var isRecording = false
    var pendingEnter = false
    var activeChord: Mods?
    var captureMask: Mods = []
    var recordStart = Date()
    var capturing: Capturing = .none
    var settingsWC: SettingsWindowController?
    var overlay: PillOverlay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setIcon("🎙️")
        buildMenu()
        overlay = PillOverlay(levelProvider: { [weak self] in self?.recorder.level() ?? 0 })
        applyOverlayConfig()
        recorder.deviceUID = cfg.inputDeviceUID
        parakeet.start()
        checkPermissions()
        installEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) { parakeet.stop() }

    func applyOverlayConfig() {
        overlay?.configure(minimal: cfg.pillStyle == "minimal", appear: cfg.animAppear,
                           hide: cfg.animHide, hold: cfg.holdDuration)
    }

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
        recordStart = Date()
        setIcon(enter ? "🔴↵" : "🔴")
        overlay?.setActive(true)
        recorder.start()
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        activeChord = nil
        let enter = pendingEnter
        // Keep the pill open through transcription so we can reveal WPM inline on the right.
        setIcon("⏳")
        overlay?.stopTimer()   // freeze the live timer; WPM replaces it after transcription
        guard let wav = recorder.stop() else { overlay?.setActive(false); setIcon("🎙️"); return }
        let seconds = Date().timeIntervalSince(recordStart)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.transcriber.transcribe(wav)
            DispatchQueue.main.async {
                logf("TRANSCRIPT len=\(text.count) trusted=\(AXIsProcessTrusted()) text='\(text.prefix(80))'")
                self.paster.paste(text, pressEnter: enter)
                self.setIcon("🎙️")
                let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
                let wpm = seconds > 0.5 ? Int((Double(words) / (seconds / 60)).rounded()) : 0
                if words == 0 {
                    self.overlay?.setActive(false)      // no speech → fade out immediately
                } else if self.cfg.pillStyle == "full", wpm > 0 {
                    self.overlay?.showStats(wpm: wpm)   // WPM, linger, then fade
                } else {
                    self.overlay?.holdThenHide()        // minimal → linger, then fade
                }
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

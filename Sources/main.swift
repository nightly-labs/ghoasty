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
let VAD_PATH = modelPath("ggml-silero-v5.1.2.bin")

// ---- Transcription engines ----
let WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
let WHISPER_SERVER_BIN = "/opt/homebrew/bin/whisper-server"
let WHISPER_MODEL = modelPath("ggml-large-v3-turbo.bin")
let PARAKEET_SERVER_BIN = ROOT_DIR + "/parakeet.cpp/build/examples/server/parakeet-server"
let PARAKEET_MODEL = modelPath("parakeet-tdt-0.6b-v3-f16.gguf")

// Parakeet v3 (parakeet.cpp): ~0.1s/utterance, multilingual auto-detect, auto punctuation.
// Whisper (whisper-server): slower, needs the language whitelist + VAD workarounds.
enum Engine: String { case parakeet, whisper }

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

// ---- Languages the whitelist UI offers. (code, whisper's english name, UI label) ----
let SUPPORTED_LANGS: [(code: String, name: String, label: String)] = [
    ("pl", "polish", "Polski"),
    ("en", "english", "English"),
    ("de", "german", "Deutsch"),
    ("uk", "ukrainian", "Українська"),
    ("ru", "russian", "Русский"),
    ("es", "spanish", "Español"),
    ("fr", "french", "Français"),
    ("it", "italian", "Italiano"),
    ("pt", "portuguese", "Português"),
    ("cs", "czech", "Čeština"),
    ("nl", "dutch", "Nederlands"),
    ("ja", "japanese", "日本語"),
    ("zh", "chinese", "中文"),
]
func langLabel(_ code: String) -> String { SUPPORTED_LANGS.first { $0.code == code }?.label ?? code }
func codeForWhisperName(_ name: String) -> String? {
    SUPPORTED_LANGS.first { $0.name == name.lowercased() }?.code
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
    // Transcription engine.
    var engine: String = Engine.parakeet.rawValue

    enum CodingKeys: String, CodingKey {
        case dictateChords, dictateEnterChords, languages, prompt, inputDeviceUID, engine
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
        if let l = try? c.decode([String].self, forKey: .languages) { languages = l }
        if let p = try? c.decode(String.self, forKey: .prompt) { prompt = p }
        if let u = try? c.decode(String?.self, forKey: .inputDeviceUID) { inputDeviceUID = u }
        if let e = try? c.decode(String.self, forKey: .engine) { engine = e }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dictateChords, forKey: .dictateChords)
        try c.encode(dictateEnterChords, forKey: .dictateEnterChords)
        try c.encode(languages, forKey: .languages)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(engine, forKey: .engine)
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

// Runs whichever engine's local HTTP server is selected, model resident. Only one runs at
// a time (saves RAM); switching stops the old and starts the new.
final class EngineManager {
    private var proc: Process?
    private(set) var engine: Engine = .parakeet

    func start(_ engine: Engine, prompt: String) {
        self.engine = engine
        let p = Process()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        switch engine {
        case .parakeet:
            guard FileManager.default.fileExists(atPath: PARAKEET_SERVER_BIN) else {
                logf("parakeet-server missing — run build.sh"); return
            }
            p.executableURL = URL(fileURLWithPath: PARAKEET_SERVER_BIN)
            p.arguments = ["--model", PARAKEET_MODEL, "--host", "127.0.0.1", "--port", "8090"]
        case .whisper:
            p.executableURL = URL(fileURLWithPath: WHISPER_SERVER_BIN)
            var args = ["-m", WHISPER_MODEL, "--host", "127.0.0.1", "--port", "8080", "-l", "auto"]
            if FileManager.default.fileExists(atPath: VAD_PATH) { args += ["--vad", "--vad-model", VAD_PATH] }
            if !prompt.isEmpty { args += ["--prompt", prompt, "--carry-initial-prompt"] }
            p.arguments = args
        }
        do { try p.run(); proc = p; logf("engine \(engine.rawValue) starting") }
        catch { logf("engine \(engine.rawValue) failed to start: \(error)") }
    }

    func stop() { proc?.terminate(); proc?.waitUntilExit(); proc = nil }

    func switchTo(_ engine: Engine, prompt: String) { stop(); start(engine, prompt: prompt) }
}

final class Transcriber {
    static let whisperEndpoint = URL(string: "http://127.0.0.1:8080/inference")!
    static let parakeetEndpoint = URL(string: "http://127.0.0.1:8090/v1/audio/transcriptions")!

    func transcribe(_ wav: URL, engine: Engine, languages: [String]) -> String {
        switch engine {
        case .parakeet: return parakeetTranscribe(wav)
        case .whisper:  return whisperTranscribe(wav, languages: languages)
        }
    }

    // Parakeet: multilingual auto-detect + punctuation built in — no whitelist/VAD needed.
    private func parakeetTranscribe(_ wav: URL) -> String {
        let r = post(Transcriber.parakeetEndpoint, wav: wav,
                     fields: ["language": "auto", "response_format": "text"], verbose: false)
        return r.text ?? ""
    }

    // Whisper: language whitelist (1 → forced; >1 → auto confined to the set; empty → full auto).
    private func whisperTranscribe(_ wav: URL, languages: [String]) -> String {
        let primary = languages.first ?? "auto"
        if languages.count <= 1 {
            let r = post(Transcriber.whisperEndpoint, wav: wav,
                         fields: ["language": primary, "response_format": "text"], verbose: false)
            return r.text ?? cliTranscribe(wav, language: primary)
        }
        let r = post(Transcriber.whisperEndpoint, wav: wav,
                     fields: ["language": "auto", "response_format": "verbose_json"], verbose: true)
        guard let text = r.text else { return cliTranscribe(wav, language: primary) }
        if text.isEmpty { return "" }                       // VAD: no speech
        if let d = codeForWhisperName(r.detectedLang), languages.contains(d) { return text }
        logf("lang '\(r.detectedLang)' outside whitelist → redo as \(primary)")
        return post(Transcriber.whisperEndpoint, wav: wav,
                    fields: ["language": primary, "response_format": "text"], verbose: false).text ?? ""
    }

    // Shared OpenAI-style multipart POST. text == nil → request failed.
    private func post(_ url: URL, wav: URL, fields: [String: String], verbose: Bool)
        -> (text: String?, detectedLang: String) {
        guard let audio = try? Data(contentsOf: wav) else { return (nil, "") }
        let boundary = "WisprLiteBoundary7MA4YWxkTrZu0gW"
        var body = Data()
        body.appendStr("--\(boundary)\r\n")
        body.appendStr("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n")
        body.appendStr("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        for (k, v) in fields {
            body.appendStr("\r\n--\(boundary)\r\n")
            body.appendStr("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)")
        }
        body.appendStr("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var out: (text: String?, detectedLang: String) = (nil, "")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            guard let data else { return }
            if verbose, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out = (text, obj["language"] as? String ?? "")
            } else if let s = String(data: data, encoding: .utf8) {
                out = (s.trimmingCharacters(in: .whitespacesAndNewlines), "")
            }
        }.resume()
        sem.wait()
        return out
    }

    private func cliTranscribe(_ wav: URL, language: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: WHISPER_CLI)
        p.arguments = ["-m", WHISPER_MODEL, "-f", wav.path, "-l", language.isEmpty ? "auto" : language, "-nt", "-np"]
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
    private let langChips = NSStackView()
    private let dictateAddBtn = NSButton(title: "＋ Add key", target: nil, action: nil)
    private let enterAddBtn = NSButton(title: "＋ Add key", target: nil, action: nil)
    private let addLangBtn = NSButton(title: "＋ Add language", target: nil, action: nil)
    private let micPopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()

    static func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        return l
    }

    convenience init(app: AppDelegate) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "WisprLite Settings"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        self.app = app

        let title = NSTextField(labelWithString: "Hotkeys")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        for cs in [dictateChips, enterChips, langChips] {
            cs.orientation = .horizontal; cs.spacing = 8; cs.alignment = .centerY
        }
        dictateAddBtn.target = self; dictateAddBtn.action = #selector(recordDictate)
        enterAddBtn.target = self; enterAddBtn.action = #selector(recordEnter)
        addLangBtn.target = self; addLangBtn.action = #selector(addLanguage)
        dictateAddBtn.bezelStyle = .rounded; enterAddBtn.bezelStyle = .rounded; addLangBtn.bezelStyle = .rounded
        dictateAddBtn.title = "＋ Add combo"; enterAddBtn.title = "＋ Add combo"
        micPopup.target = self; micPopup.action = #selector(pickMic)
        enginePopup.target = self; enginePopup.action = #selector(pickEngine)

        let grid = NSGridView(views: [
            [SettingsWindowController.caption("Engine"), enginePopup],
            [SettingsWindowController.caption("Dictate"), dictateChips],
            [SettingsWindowController.caption("Dictate + Enter"), enterChips],
            [SettingsWindowController.caption("Languages"), langChips],
            [SettingsWindowController.caption("Microphone"), micPopup],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        for i in 0..<5 { grid.row(at: i).yPlacement = .center }

        let hint = NSTextField(wrappingLabelWithString:
            "Engine: Parakeet auto-detects language & punctuates (Languages row is ignored). Whisper uses the Languages whitelist. "
            + "Hotkeys: add modifier combos (⌥, ⌘⇧, ⌃⌥, Fn…) — any starts dictation; “Dictate + Enter” also presses Return. "
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

        for v in langChips.arrangedSubviews { langChips.removeArrangedSubview(v); v.removeFromSuperview() }
        for code in app?.cfg.languages ?? [] { langChips.addArrangedSubview(langChip(code)) }
        langChips.addArrangedSubview(addLangBtn)

        enginePopup.removeAllItems()
        enginePopup.addItem(withTitle: "Parakeet v3 — fast, multilingual (recommended)")
        enginePopup.lastItem?.representedObject = Engine.parakeet.rawValue
        enginePopup.addItem(withTitle: "Whisper Large v3 Turbo")
        enginePopup.lastItem?.representedObject = Engine.whisper.rawValue
        enginePopup.selectItem(at: app?.cfg.engine == Engine.whisper.rawValue ? 1 : 0)

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

    @objc func pickEngine(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let e = Engine(rawValue: raw) else { return }
        app?.setEngine(e)
    }

    private func langChip(_ code: String) -> NSButton {
        let b = NSButton(title: "\(langLabel(code))  ✕", target: self, action: #selector(removeLang(_:)))
        b.bezelStyle = .rounded
        b.identifier = NSUserInterfaceItemIdentifier(code)
        return b
    }

    @objc func addLanguage() {
        let existing = Set(app?.cfg.languages ?? [])
        let menu = NSMenu()
        for l in SUPPORTED_LANGS where !existing.contains(l.code) {
            let it = menu.addItem(withTitle: l.label, action: #selector(pickLang(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.code
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "(all added)", action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addLangBtn.bounds.height + 4), in: addLangBtn)
    }

    @objc func pickLang(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let app else { return }
        if !app.cfg.languages.contains(code) { app.cfg.languages.append(code) }
        app.cfg.save(); app.buildMenu(); refresh()
    }

    @objc func removeLang(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue, let app else { return }
        app.cfg.languages.removeAll { $0 == code }
        app.cfg.save(); app.buildMenu(); refresh()
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
    let engines = EngineManager()
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
        recorder.deviceUID = cfg.inputDeviceUID
        engines.start(Engine(rawValue: cfg.engine) ?? .parakeet, prompt: cfg.prompt)
        checkPermissions()
        installEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) { engines.stop() }

    func setEngine(_ engine: Engine) {
        cfg.engine = engine.rawValue
        cfg.save()
        buildMenu()
        setIcon("⏳")
        DispatchQueue.global().async {
            self.engines.switchTo(engine, prompt: self.cfg.prompt)
            DispatchQueue.main.async { self.setIcon("🎙️") }
        }
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
        let langs = cfg.languages
        let engine = engines.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.transcriber.transcribe(wav, engine: engine, languages: langs)
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
        let langs = cfg.languages.isEmpty ? "auto (all)" : cfg.languages.map(langLabel).joined(separator: ", ")
        menu.addItem(withTitle: "Languages:  \(langs)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Engine:  \(cfg.engine == "parakeet" ? "Parakeet v3" : "Whisper turbo")", action: nil, keyEquivalent: "")
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

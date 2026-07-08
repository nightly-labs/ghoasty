import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import ServiceManagement

// WisprLite — push-to-talk local dictation.
// Hold a bound modifier to record, release to transcribe (whisper.cpp) and paste.
// Two bindings: plain dictate, and dictate+Enter (presses Return after pasting).

let ROOT_DIR = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
let MODELS_DIR = ROOT_DIR + "/models"
func modelPath(_ file: String) -> String { MODELS_DIR + "/" + file }

// Parakeet (parakeet.cpp): ~0.1s/utterance, auto punctuation, resident server on :8090.
let PARAKEET_SERVER_BIN = ROOT_DIR + "/parakeet.cpp/build/examples/server/parakeet-server"

// Predefined models the app can download (from mudler/parakeet-cpp-gguf).
struct ModelInfo { let key: String; let file: String; let url: String; let label: String }
let MODELS: [ModelInfo] = [
    ModelInfo(key: "multilingual",
              file: "parakeet-tdt-0.6b-v3-f16.gguf",
              url: "https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v3-f16.gguf",
              label: "Multilingual (v3) — 25 languages incl. Polish"),
    ModelInfo(key: "english",
              file: "parakeet-tdt-0.6b-v2-f16.gguf",
              url: "https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v2-f16.gguf",
              label: "English only (v2) — most accurate for English"),
]
func modelInfo(_ key: String) -> ModelInfo { MODELS.first { $0.key == key } ?? MODELS[0] }
func modelDownloaded(_ key: String) -> Bool { FileManager.default.fileExists(atPath: modelPath(modelInfo(key).file)) }

// ---- Permissions ----
func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
func micGranted() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
func openPrivacyPane(_ anchor: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(u)
    }
}

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
    // Leave the transcript on the clipboard after pasting (off → restore previous clipboard).
    var leaveInClipboard: Bool = false
    // Text replacements applied to every transcript: each entry is [from, to].
    var replacements: [[String]] = []
    // Boost/gate the mic signal before transcription (helps a quiet/distant built-in mic).
    var boostMic: Bool = true
    // Play a subtle sound when recording starts / stops.
    var playSounds: Bool = false
    // Selected transcription model key (see MODELS).
    var model: String = "multilingual"

    enum CodingKeys: String, CodingKey {
        case dictateChords, dictateEnterChords, inputDeviceUID
        case pillStyle, animAppear, animHide, holdDuration, leaveInClipboard, replacements
        case boostMic, playSounds, model
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
        if let b = try? c.decode(Bool.self, forKey: .leaveInClipboard) { leaveInClipboard = b }
        if let r = try? c.decode([[String]].self, forKey: .replacements) { replacements = r }
        if let b = try? c.decode(Bool.self, forKey: .boostMic) { boostMic = b }
        if let b = try? c.decode(Bool.self, forKey: .playSounds) { playSounds = b }
        if let m = try? c.decode(String.self, forKey: .model) { model = m }
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
        try c.encode(leaveInClipboard, forKey: .leaveInClipboard)
        try c.encode(replacements, forKey: .replacements)
        try c.encode(boostMic, forKey: .boostMic)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(model, forKey: .model)
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

// ---- Recent dictations, newest first, persisted to ~/.wisprlite/history.json ----
final class History {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".wisprlite/history.json")
    private(set) var items: [String] = []

    init() {
        if let d = try? Data(contentsOf: History.url),
           let a = try? JSONDecoder().decode([String].self, from: d) { items = a }
    }
    func add(_ text: String) {
        items.insert(text, at: 0)
        if items.count > 50 { items = Array(items.prefix(50)) }
        save()
    }
    func clear() { items = []; save() }
    private func save() {
        try? FileManager.default.createDirectory(
            at: History.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: History.url)
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
    var boost = true                // AGC + noise gate before transcription
    private var runningPeak: Float = 0.05
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
        runningPeak = 0.05

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
            var sum: Float = 0, peak: Float = 0
            for i in 0..<n { let s = ch[i]; sum += s * s; peak = max(peak, abs(s)) }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            let db = 20 * log10f(max(rms, 1e-7))
            curLevel = CGFloat(max(0, min(1, (db + 50) / 50)))

            if boost {
                // AGC toward a target peak (never attenuates loud input, caps the boost) +
                // a gentle noise gate so near-silent frames don't get amplified into the model.
                runningPeak = max(peak, runningPeak * 0.999)
                let gain = min(Float(6), max(Float(1), 0.5 / max(runningPeak, 0.01)))
                let gate: Float = rms < 0.004 ? 0.15 : 1.0
                let g = gain * gate
                for i in 0..<n { ch[i] = max(-1, min(1, ch[i] * g)) }
            }
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

// User dictionary: case-insensitive text replacements applied to every transcript.
func applyReplacements(_ text: String, _ rules: [[String]]) -> String {
    var out = text
    for r in rules where r.count == 2 && !r[0].isEmpty {
        out = out.replacingOccurrences(of: r[0], with: r[1], options: [.caseInsensitive])
    }
    return out
}

// Keeps the Parakeet model resident in parakeet-server (OpenAI-compatible) on port 8090.
final class ParakeetServer {
    private var proc: Process?
    private(set) var ready = false
    var onReady: (() -> Void)?

    func start(modelPath: String) {
        ready = false
        guard FileManager.default.fileExists(atPath: PARAKEET_SERVER_BIN),
              FileManager.default.fileExists(atPath: modelPath) else {
            logf("parakeet-server or model missing — run build.sh / download model"); return
        }
        // Clear any orphaned server (e.g. from a previous crash) so port 8090 is free.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-x", "parakeet-server"]
        try? kill.run(); kill.waitUntilExit()
        usleep(200_000)

        let p = Process()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.executableURL = URL(fileURLWithPath: PARAKEET_SERVER_BIN)
        p.arguments = ["--model", modelPath, "--host", "127.0.0.1", "--port", "8090"]
        do { try p.run(); proc = p; logf("parakeet-server starting (\(modelPath.split(separator: "/").last ?? ""))"); pollReady() }
        catch { logf("parakeet-server failed to start: \(error)") }
    }

    func stop() { proc?.terminate(); proc?.waitUntilExit(); proc = nil }

    // Poll until the model has loaded and the server answers, then flip `ready`.
    private func pollReady() {
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<120 {               // up to ~60s
                if self?.ping() == true {
                    DispatchQueue.main.async { self?.ready = true; self?.onReady?() }
                    return
                }
                usleep(500_000)
            }
        }
    }

    private func ping() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8090/") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0); var up = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if resp is HTTPURLResponse { up = true }   // any HTTP reply = server is listening
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return up
    }
}

// Downloads a file with progress via URLSession.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var destPath = ""
    var onProgress: ((Double) -> Void)?
    var onDone: ((Bool) -> Void)?

    func download(_ url: URL, to path: String) {
        destPath = path
        session.downloadTask(with: url).resume()
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            onDone?(false); return
        }
        try? FileManager.default.removeItem(atPath: destPath)
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destPath))
            onDone?(true)
        } catch { logf("move failed: \(error)"); onDone?(false) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { logf("download error: \(error)"); onDone?(false) }   // success handled above
    }
}

final class Transcriber {
    static let endpoint = URL(string: "http://127.0.0.1:8090/v1/audio/transcriptions")!

    // Parakeet is multilingual with built-in language auto-detect + punctuation.
    // Returns nil on request failure (e.g. server still warming up); "" = no speech.
    // Retries a few times so dictating during model warm-up still lands.
    func transcribe(_ wav: URL) -> String? {
        guard let audio = try? Data(contentsOf: wav) else { return nil }
        for attempt in 0..<4 {
            if let text = post(audio) { return text }
            if attempt < 3 { usleep(500_000) }   // server likely still loading — wait & retry
        }
        return nil
    }

    private func post(_ audio: Data) -> String? {
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
        var result: String? = nil
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data, let s = String(data: data, encoding: .utf8) else { return }
            result = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
    func paste(_ text: String, pressEnter: Bool, keepInClipboard: Bool) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general

        // Snapshot the current clipboard so we can restore it (unless the user opts to keep
        // the transcript). Copies every type of every item.
        let saved: [NSPasteboardItem]? = keepInClipboard ? nil : pb.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(0x09, flags: .maskCommand)  // Cmd+V
        if pressEnter {
            usleep(30_000)                   // let paste land before Return
            postKey(0x24)                    // Return
        }

        if let saved {
            // Restore after the paste has been consumed by the target app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
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

    private var lastVisible = false
    func tick() {
        let rate = presenceTarget > presence ? appearRate : hideRate
        presence += (presenceTarget - presence) * rate
        wpmDisplay += (wpmTarget - wpmDisplay) * 0.28
        let raw = (recStart != nil ? (levelProvider?() ?? 0) : 0)
        level += (raw - level) * 0.35          // smooth
        phase += 0.5
        // Only redraw while the pill is (or just became) visible — no 60 fps spin when idle.
        let visible = presence > 0.003 || presenceTarget > 0.003
        if visible || lastVisible { needsDisplay = true }
        lastVisible = visible
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

// Time (ms) for a per-frame lerp at `rate` to reach ~95% of target, at 60 fps.
func settleMs(_ rate: Double) -> Int {
    let r = min(max(rate, 0.01), 0.99)
    let frames = log(0.05) / log(1 - r)
    return Int((frames / 60.0 * 1000).rounded())
}

// Inverse of settleMs: the lerp rate that settles in ~`ms` at 60 fps.
func rateForSettleMs(_ ms: Int) -> Double {
    let frames = max(Double(ms) / 1000.0 * 60.0, 1)
    return 1 - exp(log(0.05) / frames)
}

// ---- Settings window ----
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
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
    private let appearVal = SettingsWindowController.valueField()
    private let hideVal = SettingsWindowController.valueField()
    private let holdVal = SettingsWindowController.valueField()
    private let clipboardCheck = NSButton(checkboxWithTitle: "Leave transcript in clipboard", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch WisprLite at login", target: nil, action: nil)
    private let boostCheck = NSButton(checkboxWithTitle: "Boost quiet microphone", target: nil, action: nil)
    private let soundCheck = NSButton(checkboxWithTitle: "Play start / stop sound", target: nil, action: nil)
    private let modelList = NSStackView()
    private let accStatus = NSTextField(labelWithString: "")
    private let micStatus = NSTextField(labelWithString: "")
    private let dictBtn = NSButton(title: "Edit dictionary…", target: nil, action: nil)

    static func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabelColor
        return l
    }

    // Editable ms field: user can drag the slider or type an exact value.
    static func valueField() -> NSTextField {
        let f = NSTextField(string: "")
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.alignment = .right
        f.isEditable = true
        f.isSelectable = true
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.controlSize = .small
        f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return f
    }

    private func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        let s = NSStackView(views: [slider, value])
        s.orientation = .horizontal; s.spacing = 8; s.alignment = .centerY
        return s
    }

    private func permRow(_ status: NSTextField, _ action: Selector) -> NSStackView {
        status.font = .systemFont(ofSize: 12)
        status.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let btn = NSButton(title: "Open Settings", target: self, action: action)
        btn.bezelStyle = .rounded; btn.controlSize = .small
        let s = NSStackView(views: [status, btn]); s.orientation = .horizontal; s.spacing = 10; s.alignment = .centerY
        return s
    }
    private func setPermLabel(_ l: NSTextField, _ ok: Bool) {
        l.stringValue = ok ? "✓ Granted" : "✕ Not granted"
        l.textColor = ok ? .systemGreen : .systemOrange
    }

    private func updateAnimLabels() {
        appearVal.stringValue = "\(settleMs(appearSlider.doubleValue)) ms"
        hideVal.stringValue = "\(settleMs(hideSlider.doubleValue)) ms"
        holdVal.stringValue = "\(Int((holdSlider.doubleValue * 1000).rounded())) ms"
    }

    convenience init(app: AppDelegate) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "WisprLite Settings"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        self.app = app

        let title = NSTextField(labelWithString: "WisprLite Settings")
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
        clipboardCheck.target = self; clipboardCheck.action = #selector(toggleClipboard)
        loginCheck.target = self; loginCheck.action = #selector(toggleLogin)
        boostCheck.target = self; boostCheck.action = #selector(toggleBoost)
        soundCheck.target = self; soundCheck.action = #selector(toggleSound)
        modelList.orientation = .vertical; modelList.alignment = .leading; modelList.spacing = 8
        dictBtn.target = self; dictBtn.action = #selector(openDictionary); dictBtn.bezelStyle = .rounded
        win.delegate = self   // refresh permission status when the window regains focus
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
        for f in [appearVal, hideVal, holdVal] {
            f.target = self; f.action = #selector(editAnimValue)
        }

        let grid = NSGridView(views: [
            [SettingsWindowController.caption("Accessibility"), permRow(accStatus, #selector(openAcc))],
            [SettingsWindowController.caption("Microphone"), permRow(micStatus, #selector(openMic))],
            [SettingsWindowController.caption("Model"), modelList],
            [SettingsWindowController.caption("Dictate"), dictateChips],
            [SettingsWindowController.caption("Dictate + Enter"), enterChips],
            [SettingsWindowController.caption("Input device"), micPopup],
            [SettingsWindowController.caption(""), boostCheck],
            [SettingsWindowController.caption("Clipboard"), clipboardCheck],
            [SettingsWindowController.caption("Dictionary"), dictBtn],
            [SettingsWindowController.caption("Startup"), loginCheck],
            [SettingsWindowController.caption("Sound"), soundCheck],
            [SettingsWindowController.caption("Overlay"), stylePopup],
            [SettingsWindowController.caption("Appear speed"), sliderRow(appearSlider, appearVal)],
            [SettingsWindowController.caption("Hide speed"), sliderRow(hideSlider, hideVal)],
            [SettingsWindowController.caption("Show after release"), sliderRow(holdSlider, holdVal)],
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        for i in 0..<15 { grid.row(at: i).yPlacement = .center }

        let hint = NSTextField(wrappingLabelWithString:
            "Hotkeys: add modifier combos (⌥, ⌘⇧, ⌃⌥, Fn…) — any starts dictation; “Dictate + Enter” also presses Return. "
            + "Parakeet auto-detects the language and adds punctuation. "
            + "Microphone: built-in keeps Bluetooth output in high quality. Click a chip to remove it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let resetBtn = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        resetBtn.bezelStyle = .rounded

        let stack = NSStackView(views: [title, grid, hint, resetBtn])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            hint.widthAnchor.constraint(equalToConstant: 560),
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
        clipboardCheck.state = (app?.cfg.leaveInClipboard ?? false) ? .on : .off
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        boostCheck.state = (app?.cfg.boostMic ?? true) ? .on : .off
        soundCheck.state = (app?.cfg.playSounds ?? false) ? .on : .off

        setPermLabel(accStatus, accessibilityGranted())
        setPermLabel(micStatus, micGranted())

        for v in modelList.arrangedSubviews { modelList.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, m) in MODELS.enumerated() { modelList.addArrangedSubview(modelRow(m, index: i)) }

        updateAnimLabels()

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

    @objc func resetDefaults() {
        let a = NSAlert()
        a.messageText = "Reset all settings to defaults?"
        a.informativeText = "Hotkeys, microphone, overlay and other preferences will be restored."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { app?.resetConfig() }
    }

    @objc func openDictionary() { app?.openDict() }

    @objc func openAcc() { openPrivacyPane("Privacy_Accessibility") }
    @objc func openMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }
    @objc func useOrDownload(_ sender: NSButton) {
        guard sender.tag < MODELS.count else { return }
        app?.setModel(MODELS[sender.tag].key)
    }

    @objc func deleteModelRow(_ sender: NSButton) {
        guard sender.tag < MODELS.count else { return }
        let m = MODELS[sender.tag]
        let a = NSAlert()
        a.messageText = "Delete “\(m.label)”?"
        a.informativeText = "The model file is removed. You can download it again later."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { app?.deleteModel(m.key) }
    }

    private func modelRow(_ m: ModelInfo, index: Int) -> NSStackView {
        let downloaded = modelDownloaded(m.key)
        let active = app?.cfg.model == m.key
        let isDownloading = app?.downloadingKey == m.key

        let check = NSTextField(labelWithString: downloaded ? "✓" : "○")
        check.textColor = downloaded ? .systemGreen : .tertiaryLabelColor
        check.font = .systemFont(ofSize: 13, weight: .bold)
        check.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let label = NSTextField(labelWithString: m.label + (active ? "  ·  active" : ""))
        label.font = .systemFont(ofSize: 12)

        let right: NSView
        if isDownloading {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
            bar.doubleValue = app?.downloadProgress ?? 0
            bar.controlSize = .small
            bar.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let pct = NSTextField(labelWithString: "\(Int((app?.downloadProgress ?? 0) * 100))%")
            pct.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            pct.textColor = .secondaryLabelColor
            let s = NSStackView(views: [bar, pct]); s.spacing = 6; s.alignment = .centerY
            right = s
        } else if active {
            right = NSView()
        } else if downloaded {
            let use = NSButton(title: "Use", target: self, action: #selector(useOrDownload(_:)))
            let del = NSButton(title: "Delete", target: self, action: #selector(deleteModelRow(_:)))
            for b in [use, del] { b.bezelStyle = .rounded; b.controlSize = .small; b.tag = index }
            let s = NSStackView(views: [use, del]); s.spacing = 6; s.alignment = .centerY
            right = s
        } else {
            let b = NSButton(title: "Download", target: self, action: #selector(useOrDownload(_:)))
            b.bezelStyle = .rounded; b.controlSize = .small; b.tag = index
            right = b
        }

        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [check, label, spacer, right])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 330).isActive = true
        return row
    }

    @objc func toggleClipboard(_ sender: NSButton) {
        app?.cfg.leaveInClipboard = (sender.state == .on)
        app?.cfg.save()
    }

    @objc func toggleBoost(_ sender: NSButton) {
        app?.cfg.boostMic = (sender.state == .on)
        app?.cfg.save()
        app?.recorder.boost = (sender.state == .on)
    }

    @objc func toggleSound(_ sender: NSButton) {
        app?.cfg.playSounds = (sender.state == .on)
        app?.cfg.save()
    }

    @objc func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            logf("login item toggle failed: \(error)")
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc func pickStyle(_ sender: NSPopUpButton) {
        guard let app, let s = sender.selectedItem?.representedObject as? String else { return }
        app.cfg.pillStyle = s
        app.cfg.save(); app.applyOverlayConfig(); app.buildMenu()
    }

    @objc func changeAnim(_ sender: NSSlider) {
        commitAnim()
    }

    // User typed an exact ms value — convert back to the slider's internal unit, clamp, sync.
    @objc func editAnimValue(_ sender: NSTextField) {
        let ms = Int(sender.stringValue.filter { $0.isNumber }) ?? 0
        if sender === holdVal {
            holdSlider.doubleValue = min(max(Double(ms) / 1000.0, holdSlider.minValue), holdSlider.maxValue)
        } else {
            let slider = (sender === appearVal) ? appearSlider : hideSlider
            slider.doubleValue = min(max(rateForSettleMs(ms), slider.minValue), slider.maxValue)
        }
        commitAnim()
    }

    // Read the sliders into config, persist, apply, and re-render the ms fields.
    private func commitAnim() {
        guard let app else { return }
        app.cfg.animAppear = appearSlider.doubleValue
        app.cfg.animHide = hideSlider.doubleValue
        app.cfg.holdDuration = holdSlider.doubleValue
        app.cfg.save(); app.applyOverlayConfig()
        updateAnimLabels()
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

// ---- Dictionary editor (text replacements) ----
final class DictWindowController: NSWindowController, NSWindowDelegate {
    weak var app: AppDelegate?
    private let rows = NSStackView()

    convenience init(app: AppDelegate) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Dictionary"; win.isReleasedWhenClosed = false
        self.init(window: win); self.app = app
        win.delegate = self

        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8

        let addBtn = NSButton(title: "＋ Add replacement", target: self, action: #selector(addPair))
        addBtn.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString:
            "Applied to every transcript (case-insensitive). Example: “solona” → “Solana”.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 400).isActive = true

        let stack = NSStackView(views: [rows, addBtn, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        refresh()
    }

    func refresh() {
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
        for pair in app?.cfg.replacements ?? [] {
            rows.addArrangedSubview(makeRow(pair.first ?? "", pair.count > 1 ? pair[1] : ""))
        }
    }

    private func field(_ s: String, placeholder: String) -> NSTextField {
        let tf = NSTextField(string: s)
        tf.placeholderString = placeholder
        tf.target = self; tf.action = #selector(commit)
        tf.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return tf
    }

    private func makeRow(_ from: String, _ to: String) -> NSStackView {
        let arrow = NSTextField(labelWithString: "→"); arrow.textColor = .secondaryLabelColor
        let remove = NSButton(title: "✕", target: self, action: #selector(removePair(_:)))
        remove.bezelStyle = .rounded
        let row = NSStackView(views: [field(from, placeholder: "heard"), arrow,
                                      field(to, placeholder: "replace with"), remove])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }

    @objc private func addPair() { commit(); app?.cfg.replacements.append(["", ""]); refresh() }

    @objc private func removePair(_ sender: NSButton) {
        if let row = sender.superview as? NSStackView { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        commit()
    }

    @objc private func commit() {
        var pairs: [[String]] = []
        for case let row as NSStackView in rows.arrangedSubviews {
            let subs = row.arrangedSubviews
            guard subs.count >= 3,
                  let f = (subs[0] as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespaces),
                  let t = (subs[2] as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespaces)
            else { continue }
            if !f.isEmpty { pairs.append([f, t]) }
        }
        app?.cfg.replacements = pairs
        app?.cfg.save()
    }

    func windowWillClose(_ notification: Notification) { commit() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// ---- First-run setup: permissions + model download ----
final class OnboardWindowController: NSWindowController, NSWindowDelegate {
    weak var app: AppDelegate?
    private let micStatus = NSTextField(labelWithString: "")
    private let accStatus = NSTextField(labelWithString: "")
    private let modelStatus = NSTextField(labelWithString: "")
    private let micBtn = NSButton(title: "Grant", target: nil, action: nil)
    private let accBtn = NSButton(title: "Grant", target: nil, action: nil)
    private let modelBtn = NSButton(title: "Download", target: nil, action: nil)
    private var timer: Timer?

    convenience init(app: AppDelegate) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Welcome to WisprLite"; win.isReleasedWhenClosed = false
        self.init(window: win); self.app = app; win.delegate = self

        let title = NSTextField(labelWithString: "Welcome to WisprLite")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Grant two permissions and download a model to start dictating.")
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor

        micBtn.target = self; micBtn.action = #selector(grantMic)
        accBtn.target = self; accBtn.action = #selector(grantAcc)
        modelBtn.target = self; modelBtn.action = #selector(downloadStep)
        for b in [micBtn, accBtn, modelBtn] { b.bezelStyle = .rounded }

        let grid = NSGridView(views: [
            [step("1. Microphone"), micStatus, micBtn],
            [step("2. Accessibility"), accStatus, accBtn],
            [step("3. Model"), modelStatus, modelBtn],
        ])
        grid.rowSpacing = 16; grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .leading
        for i in 0..<3 { grid.row(at: i).yPlacement = .center }

        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, subtitle, grid, done])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        win.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            stack.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
        ])
        win.center()
        refresh()
    }

    private func step(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 13, weight: .medium)
        l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return l
    }
    private func setStatus(_ l: NSTextField, _ ok: Bool, _ pendingText: String? = nil) {
        if let p = pendingText { l.stringValue = p; l.textColor = .secondaryLabelColor; return }
        l.stringValue = ok ? "✓ Ready" : "✕ Not yet"
        l.textColor = ok ? .systemGreen : .systemOrange
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
    }

    func refresh() {
        setStatus(micStatus, micGranted()); micBtn.isEnabled = !micGranted()
        setStatus(accStatus, accessibilityGranted()); accBtn.isEnabled = !accessibilityGranted()
        let key = app?.cfg.model ?? "multilingual"
        if app?.downloading == true {
            setStatus(modelStatus, false, "Downloading… \(Int((app?.downloadProgress ?? 0) * 100))%")
            modelBtn.isEnabled = false
        } else {
            let dl = modelDownloaded(key)
            setStatus(modelStatus, dl); modelBtn.isEnabled = !dl
        }
    }

    @objc private func grantMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else { openPrivacyPane("Privacy_Microphone") }
    }
    @objc private func grantAcc() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPrivacyPane("Privacy_Accessibility")
    }
    @objc private func downloadStep() { app?.setModel(app?.cfg.model ?? "multilingual") }
    @objc private func finish() { window?.close() }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    func show() {
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        }
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
    let history = History()
    var eventTap: CFMachPort?
    var cfg = Config.load()
    var isRecording = false
    var pendingEnter = false
    var activeChord: Mods?
    var captureMask: Mods = []
    var recordStart = Date()
    var capturing: Capturing = .none
    var settingsWC: SettingsWindowController?
    var dictWC: DictWindowController?
    var onboardWC: OnboardWindowController?
    var overlay: PillOverlay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy is already running, hand off and quit.
        let bid = Bundle.main.bundleIdentifier ?? "com.local.wisprlite"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0 != .current }
        if !others.isEmpty { others.first?.activate(); NSApp.terminate(nil); return }

        setState(.warming)                         // warming up until the model loads
        buildMenu()
        overlay = PillOverlay(levelProvider: { [weak self] in self?.recorder.level() ?? 0 })
        applyOverlayConfig()
        recorder.deviceUID = cfg.inputDeviceUID
        recorder.boost = cfg.boostMic
        parakeet.onReady = { [weak self] in self?.setState(.ready) }
        parakeet.start(modelPath: modelPath(modelInfo(cfg.model).file))
        checkPermissions()
        installEventTap()

        // First run / incomplete setup → guide the user through permissions + model.
        if !accessibilityGranted() || !modelDownloaded(cfg.model) { openOnboarding() }
    }

    func openOnboarding() {
        if onboardWC == nil { onboardWC = OnboardWindowController(app: self) }
        onboardWC?.show()
    }

    func applicationWillTerminate(_ notification: Notification) { parakeet.stop() }

    func applyOverlayConfig() {
        overlay?.configure(minimal: cfg.pillStyle == "minimal", appear: cfg.animAppear,
                           hide: cfg.animHide, hold: cfg.holdDuration)
    }

    var downloadingKey: String?          // which model is downloading (nil = none)
    var downloadProgress: Double = 0     // 0…1
    var downloading: Bool { downloadingKey != nil }
    private let downloader = Downloader()

    // Switch model: download if we don't have it yet, then (re)start the server on it.
    func setModel(_ key: String, then: (() -> Void)? = nil) {
        cfg.model = key; cfg.save(); buildMenu(); refreshModelUI()
        if modelDownloaded(key) { restartServer(); then?() }
        else { downloadModel(modelInfo(key)) { [weak self] ok in if ok { self?.restartServer() }; then?() } }
    }

    // Delete a downloaded model file (not the active one).
    func deleteModel(_ key: String) {
        guard key != cfg.model else { return }
        try? FileManager.default.removeItem(atPath: modelPath(modelInfo(key).file))
        logf("deleted model \(key)")
        refreshModelUI(); buildMenu()
    }

    func restartServer() {
        setState(.warming)
        let path = modelPath(modelInfo(cfg.model).file)
        DispatchQueue.global().async { [weak self] in
            self?.parakeet.stop()
            self?.parakeet.start(modelPath: path)
        }
    }

    private func refreshModelUI() { settingsWC?.refresh(); onboardWC?.refresh() }

    func downloadModel(_ info: ModelInfo, done: @escaping (Bool) -> Void) {
        guard downloadingKey == nil else { return }
        downloadingKey = info.key; downloadProgress = 0
        setState(.warming); refreshModelUI()
        downloader.onProgress = { [weak self] p in
            DispatchQueue.main.async { self?.downloadProgress = p; self?.refreshModelUI() }
        }
        downloader.onDone = { [weak self] ok in
            DispatchQueue.main.async {
                self?.downloadingKey = nil
                self?.refreshModelUI()
                logf("model download \(info.key): \(ok ? "ok" : "FAILED")")
                done(ok)
            }
        }
        guard let url = URL(string: info.url) else { done(false); return }
        downloader.download(url, to: modelPath(info.file))
    }

    func resetConfig() {
        cfg = Config()                      // all defaults
        cfg.save()
        recorder.deviceUID = cfg.inputDeviceUID
        recorder.boost = cfg.boostMic
        applyOverlayConfig()
        buildMenu()
        settingsWC?.refresh()
    }

    // Request mic once if undecided. Accessibility is guided by the onboarding window.
    func checkPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        logf("accessibility \(AXIsProcessTrusted() ? "granted" : "missing")")
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
        setState(.recording)
        if cfg.playSounds { NSSound(named: "Pop")?.play() }
        overlay?.setActive(true)
        recorder.start()
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        activeChord = nil
        let enter = pendingEnter
        // Keep the pill open through transcription so we can reveal WPM inline on the right.
        setState(.warming)
        overlay?.stopTimer()   // freeze the live timer; WPM replaces it after transcription
        guard let wav = recorder.stop() else { overlay?.setActive(false); setState(.ready); return }
        let seconds = Date().timeIntervalSince(recordStart)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.transcriber.transcribe(wav)
            DispatchQueue.main.async {
                guard let raw = result else {            // request failed (server down / warming up)
                    logf("TRANSCRIBE FAILED")
                    self.flashError()
                    self.overlay?.setActive(false)
                    return
                }
                let text = applyReplacements(raw, self.cfg.replacements)
                logf("TRANSCRIPT len=\(text.count) trusted=\(AXIsProcessTrusted()) text='\(text.prefix(80))'")
                self.paster.paste(text, pressEnter: enter, keepInClipboard: self.cfg.leaveInClipboard)
                self.setState(.ready)
                if !text.isEmpty {
                    if self.cfg.playSounds { NSSound(named: "Tink")?.play() }
                    self.history.add(text); self.buildMenu()
                }
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

    func flashError() {
        setState(.error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.setState(self?.parakeet.ready == true ? .ready : .warming)
        }
    }

    enum IconState { case warming, ready, recording, processing, error }
    func setState(_ s: IconState) {
        DispatchQueue.main.async {
            guard let btn = self.statusItem.button else { return }
            let name: String, tint: NSColor?
            switch s {
            case .warming:    name = "hourglass";                    tint = nil
            case .ready:      name = "mic";                          tint = nil
            case .recording:  name = "mic.fill";                     tint = .systemRed
            case .processing: name = "waveform";                     tint = nil
            case .error:      name = "exclamationmark.triangle.fill"; tint = .systemOrange
            }
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "WisprLite")
            img?.isTemplate = (tint == nil)          // template adapts to the menubar theme
            btn.image = img
            btn.contentTintColor = tint
            btn.title = ""
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let ver = menu.addItem(withTitle: "WisprLite 0.1 · Parakeet v3", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(.separator())
        let names = { (cs: [Int]) in cs.isEmpty ? "—" : cs.map { Mods(rawValue: $0).name }.joined(separator: ", ") }
        menu.addItem(withTitle: "Dictate:  \(names(cfg.dictateChords))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Dictate + Enter:  \(names(cfg.dictateEnterChords))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let histItem = menu.addItem(withTitle: "History", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if history.items.isEmpty {
            sub.addItem(withTitle: "(empty)", action: nil, keyEquivalent: "")
        } else {
            for t in history.items.prefix(12) {
                let flat = t.replacingOccurrences(of: "\n", with: " ")
                let title = flat.count > 44 ? String(flat.prefix(44)) + "…" : flat
                let it = sub.addItem(withTitle: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = t
            }
            sub.addItem(.separator())
            let clr = sub.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clr.target = self
        }
        histItem.submenu = sub
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

    func openDict() {
        if dictWC == nil { dictWC = DictWindowController(app: self) }
        dictWC?.show()
    }

    @objc func copyHistoryItem(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(t, forType: .string)
    }

    @objc func clearHistory() { history.clear(); buildMenu() }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

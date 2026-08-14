import Foundation

enum DictationPolicy {
    static let escapeGraceSeconds: TimeInterval = 0.200
    static let speechRMSThreshold: Float = 0.004
    static let minimumVoicedSeconds: TimeInterval = 0.120
}

struct SpeechActivityTracker {
    private(set) var voicedSeconds: TimeInterval = 0

    mutating func reset() {
        voicedSeconds = 0
    }

    mutating func observe(rms: Float, frameCount: Int, sampleRate: Double) {
        guard rms >= DictationPolicy.speechRMSThreshold,
              frameCount > 0,
              sampleRate > 0 else { return }
        voicedSeconds += Double(frameCount) / sampleRate
    }

    var hasSpeech: Bool {
        voicedSeconds >= DictationPolicy.minimumVoicedSeconds
    }
}

enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case awaitingPaste
}

struct DictationLifecycle {
    private(set) var phase: DictationPhase = .idle
    private(set) var sessionID: UInt64?
    private var nextSessionID: UInt64 = 0

    mutating func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        nextSessionID &+= 1
        sessionID = nextSessionID
        phase = .recording
        return nextSessionID
    }

    mutating func release(_ id: UInt64) -> Bool {
        guard sessionID == id, phase == .recording else { return false }
        phase = .transcribing
        return true
    }

    mutating func awaitPaste(_ id: UInt64) -> Bool {
        guard sessionID == id, phase == .transcribing else { return false }
        phase = .awaitingPaste
        return true
    }

    mutating func finish(_ id: UInt64) -> Bool {
        guard sessionID == id else { return false }
        phase = .idle
        sessionID = nil
        return true
    }

    mutating func cancel() -> UInt64? {
        guard let id = sessionID else { return nil }
        phase = .idle
        sessionID = nil
        return id
    }

    func contains(_ id: UInt64) -> Bool {
        sessionID == id
    }
}

func pasteDelay(releasedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
    max(0, DictationPolicy.escapeGraceSeconds - (now - releasedAt))
}

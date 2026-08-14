import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct DictationLogicTests {
    static func main() {
        testSpeechActivity()
        testLifecycleCancellation()
        testLifecycleBlocksOverlap()
        testPasteDelay()
        testMenuVersion()
        print("DictationLogicTests: PASS")
    }

    private static func testSpeechActivity() {
        var silence = SpeechActivityTracker()
        for _ in 0..<24 { silence.observe(rms: 0.0004, frameCount: 4096, sampleRate: 48_000) }
        expect(!silence.hasSpeech, "silence must not count as speech")

        var shortNoise = SpeechActivityTracker()
        shortNoise.observe(rms: 0.02, frameCount: 4096, sampleRate: 48_000)
        expect(!shortNoise.hasSpeech, "an 85 ms noise burst must not count as speech")

        var spokenWord = SpeechActivityTracker()
        spokenWord.observe(rms: 0.01, frameCount: 4096, sampleRate: 48_000)
        spokenWord.observe(rms: 0.01, frameCount: 4096, sampleRate: 48_000)
        expect(spokenWord.hasSpeech, "a short spoken word must count as speech")

        spokenWord.reset()
        expect(!spokenWord.hasSpeech, "a new recording must reset speech evidence")
    }

    private static func testLifecycleCancellation() {
        var lifecycle = DictationLifecycle()
        expect(lifecycle.cancel() == nil, "Escape outside dictation must pass through")
        let recordingID = lifecycle.begin()!
        expect(lifecycle.cancel() == recordingID, "Escape must cancel recording")
        expect(lifecycle.phase == .idle, "canceled recording must return to idle")
        expect(!lifecycle.finish(recordingID), "a stale recording result must not finish again")

        let transcribingID = lifecycle.begin()!
        expect(lifecycle.release(transcribingID), "release must start transcription")
        expect(lifecycle.cancel() == transcribingID, "Escape must cancel transcription")
        expect(!lifecycle.awaitPaste(transcribingID), "a canceled transcript must not reach paste")

        let waitingID = lifecycle.begin()!
        expect(lifecycle.release(waitingID), "release must start transcription")
        expect(lifecycle.awaitPaste(waitingID), "valid transcript must wait for paste")
        expect(lifecycle.cancel() == waitingID, "Escape must cancel the paste wait")
        expect(!lifecycle.finish(waitingID), "a canceled paste timer must be stale")
    }

    private static func testLifecycleBlocksOverlap() {
        var lifecycle = DictationLifecycle()
        let id = lifecycle.begin()!
        expect(lifecycle.begin() == nil, "a second recording must not overlap")
        expect(lifecycle.release(id), "release must start transcription")
        expect(lifecycle.begin() == nil, "recording must remain blocked during transcription")
        expect(lifecycle.awaitPaste(id), "transcription must enter paste wait")
        expect(lifecycle.begin() == nil, "recording must remain blocked during paste wait")
        expect(lifecycle.finish(id), "current session must finish")
        expect(lifecycle.begin() != nil, "a new recording must start after finish")
    }

    private static func testPasteDelay() {
        expect(abs(pasteDelay(releasedAt: 10, now: 10.05) - 0.15) < 0.000_001,
               "fast transcription must wait for the rest of the 200 ms window")
        expect(pasteDelay(releasedAt: 10, now: 10.20) < 0.000_001,
               "a result at the grace deadline must paste immediately")
        expect(pasteDelay(releasedAt: 10, now: 11) == 0,
               "slow transcription must not add another delay")
    }

    private static func testMenuVersion() {
        expect(ghoastyMenuTitle(version: "1.5.1") == "Ghoasty 1.5.1 · Parakeet v3",
               "the menu title must use the bundle version")
        expect(ghoastyMenuTitle(version: nil) == "Ghoasty ? · Parakeet v3",
               "the menu title must have a safe fallback")
    }
}

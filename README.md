# WisprLite

Local push-to-talk dictation for macOS (Apple Silicon). Hold a modifier combo, speak,
release — your speech is transcribed on-device and pasted where the cursor is.

- **Local & private** — audio never leaves the machine
- **Two engines** (switchable in Settings):
  - **Parakeet v3** (default) — parakeet.cpp, ~0.1s/utterance, multilingual auto-detect + automatic punctuation
  - **Whisper Large v3 Turbo** — whisper.cpp, with a language whitelist, VAD, and domain prompt
- **Push-to-talk** — bind any modifier combo (⌥, ⌘⇧, ⌃⌥, Fn…); a second combo also presses Return
- **Built-in mic capture** so Bluetooth headphones stay in high-quality output mode
- **Floating waveform pill** at the bottom of the screen, reacting to your voice

## Requirements

- Apple Silicon Mac, macOS 13+
- Xcode command-line tools (`swiftc`), `cmake`, `git`
- `brew install whisper-cpp` (for the Whisper engine)

`build.sh` clones and builds `parakeet.cpp` (with Metal) and downloads all models on first run.

## Build & run

```sh
./build.sh          # downloads the model (~1.5GB) on first run, compiles, bundles, signs
open WisprLite.app
```

The build script fetches `ggml-large-v3-turbo.bin` into `models/` (git-ignored) and signs
the app with a stable local identity so macOS permissions survive rebuilds.

## Permissions (one time)

Grant these in **System Settings → Privacy & Security**:

- **Accessibility** — required for the global hotkey (event tap) and for pasting
- **Microphone** — recording

No *Input Monitoring* needed: the hotkey uses a CGEventTap gated by Accessibility.

## Stable code signing (optional but recommended)

Rebuilds re-sign the app. Ad-hoc signatures change identity each build, so macOS forgets
permissions. To sign with a stable identity, create a self-signed code-signing cert once:

```sh
# generate + import (see repo history for the openssl recipe), then trust it:
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db wispr-cert.pem
```

`build.sh` then signs with `WisprLiteDev` automatically; permissions persist across rebuilds.

## Config

Hotkeys are stored in `~/.wisprlite/config.json` and editable from the menubar
(**Settings…**). Transcription language is forced to Polish in `Sources/main.swift`
(`serverTranscribe`) — change the `language` field as needed.

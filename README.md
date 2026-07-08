# WisprLite

Local push-to-talk dictation for macOS (Apple Silicon). Hold a modifier combo, speak,
release — your speech is transcribed on-device and pasted where the cursor is.

- **Local & private** — audio never leaves the machine
- **Parakeet v3** engine (parakeet.cpp, Metal) — ~0.1s/utterance, multilingual auto-detect + automatic punctuation
- **Push-to-talk** — bind any modifier combo (⌥, ⌘⇧, ⌃⌥, Fn…); a second combo also presses Return
- **Built-in mic capture** so Bluetooth headphones stay in high-quality output mode
- **Floating waveform pill** at the bottom of the screen, reacting to your voice (Full or Minimal style, adjustable animation)

## Requirements

- Apple Silicon Mac, macOS 13+
- Xcode command-line tools (`swiftc`), `cmake`, `git`

`build.sh` clones and builds `parakeet.cpp` (with Metal) and downloads the model on first run.

## Build & run

```sh
./build.sh          # builds parakeet.cpp + downloads the model (~1.4GB) on first run, then compiles/signs
open WisprLite.app
```

The build fetches `parakeet-tdt-0.6b-v3-f16.gguf` into `models/` (git-ignored) and signs
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

Settings (hotkeys, microphone, overlay style + animation timing) are stored in
`~/.wisprlite/config.json` and editable from the menubar (**Settings…**). Parakeet
auto-detects the spoken language, so there is no language setting to configure.

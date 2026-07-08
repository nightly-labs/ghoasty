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

## Local signing (dev)

`build.sh` signs with a stable local identity `WisprLiteDev` if present (self-signed cert; see
git history for the openssl recipe), else ad-hoc. This only makes TCC permissions
(Accessibility, Microphone) persist across rebuilds **on your own machine** — it is not
distributable.

## Distribute (Developer ID + notarization)

`dist.sh` produces a **self-contained, notarized** `WisprLite.app` and `WisprLite.dmg` that any
Apple-Silicon Mac opens with no Gatekeeper warning. It bundles `parakeet-server`, the `libggml*`
dylibs, and the default model inside the app, rewrites their rpaths to be bundle-relative, signs
inside-out with `Developer ID Application` + the hardened runtime (entitlements in
`WisprLite.entitlements` / `parakeet-server.entitlements`), then notarizes and staples both the
app and the DMG.

One-time: store notarization credentials in the keychain:

```sh
xcrun notarytool store-credentials WisprLiteNotary \
  --apple-id you@example.com --team-id ZTRDTUL87R --password <app-specific-password>
```

(App-specific password from appleid.apple.com. Signing identity is
`Developer ID Application: Akudama GmbH (ZTRDTUL87R)`.) Then:

```sh
./dist.sh                    # sign + notarize + build DMG  (NOTARY_PROFILE=... to override name)
SKIP_NOTARIZE=1 ./dist.sh    # sign + package only, no Apple round-trip (for local testing)
```

Extra models downloaded via the in-app switcher go to `~/.wisprlite/models` (the bundled default
stays read-only inside the app).

## Config

Settings (hotkeys, microphone, overlay style + animation timing) are stored in
`~/.wisprlite/config.json` and editable from the menubar (**Settings…**). Parakeet
auto-detects the spoken language, so there is no language setting to configure.

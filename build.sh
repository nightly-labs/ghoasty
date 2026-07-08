#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="WisprLite.app"
PK_MODEL="models/parakeet-tdt-0.6b-v3-f16.gguf"
PK_MODEL_URL="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v3-f16.gguf"

# 1. model — kept beside the app, not bundled
mkdir -p models
if [ ! -f "$PK_MODEL" ]; then
  echo "==> downloading Parakeet v3 model (~1.4GB)..."
  curl -L --fail -o "$PK_MODEL" "$PK_MODEL_URL"
fi

# 1b. Parakeet engine (parakeet.cpp, C++/ggml with Metal) — clone + build if missing
if [ ! -x parakeet.cpp/build/examples/server/parakeet-server ]; then
  echo "==> building parakeet.cpp (Metal)..."
  [ -d parakeet.cpp ] || git clone --depth 1 https://github.com/mudler/parakeet.cpp
  ( cd parakeet.cpp \
    && git submodule update --init --recursive --depth 1 \
    && cmake -B build -DPARAKEET_BUILD_CLI=ON -DPARAKEET_BUILD_SERVER=ON -DPARAKEET_GGML_METAL=ON \
    && cmake --build build -j )
fi

# 2. compile
echo "==> compiling..."
mkdir -p build
swiftc -O Sources/main.swift -o build/WisprLite \
  -framework AppKit -framework AVFoundation

# 3. assemble .app bundle (model referenced from ../models, not copied in)
echo "==> bundling..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/WisprLite "$APP/Contents/MacOS/WisprLite"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WisprLite</string>
  <key>CFBundleIdentifier</key><string>com.local.wisprlite</string>
  <key>CFBundleName</key><string>WisprLite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>WisprLite records your voice to transcribe it.</string>
</dict>
</plist>
PLIST

# 4. sign. Prefer the stable WisprLiteDev identity so macOS permissions
#    (Accessibility, Mic, Input Monitoring) persist across rebuilds.
#    Falls back to ad-hoc until the cert is trusted (see trust step in README).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "WisprLiteDev"; then
  echo "==> signing with stable identity WisprLiteDev"
  codesign --force --deep -s "WisprLiteDev" "$APP"
else
  echo "==> WisprLiteDev not trusted yet — signing ad-hoc (permissions won't persist)"
  codesign --force --deep -s - "$APP"
fi

echo "==> done: $PWD/$APP"
echo "Launch:  open $PWD/$APP"

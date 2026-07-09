#!/bin/bash
# Dev build: compile Ghoasty, assemble the .app, self-sign for stable local permissions.
# Production packaging (Developer ID + notarize + DMG) lives in dist.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="Ghoasty.app"
BIN="Ghoasty"
VERSION="1.2"                                   # marketing version - bump by hand for releases
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"   # monotonic build no. for Sparkle; auto-increments each commit
BUNDLE_ID="com.akudama.ghoasty"
PK_MODEL="models/parakeet-tdt-0.6b-v3-f16.gguf"
PK_MODEL_URL="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v3-f16.gguf"
# Sparkle public EdDSA key - filled in from setup-sparkle.sh output. Empty = updates disabled.
SU_FEED_URL="https://updates.ghoasty.ai/appcast.xml"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-LUBuPY2qamW1lrdak4QXEGJq/Oa1ygOM60m1CxK5438=}"

# 1. model - kept beside the app in dev; dist.sh bundles it into the app
mkdir -p models
if [ ! -f "$PK_MODEL" ]; then
  echo "==> downloading Parakeet v3 model (~1.4GB)..."
  curl -L --fail -o "$PK_MODEL" "$PK_MODEL_URL"
fi

# 1b. Parakeet engine (parakeet.cpp, C++/ggml with Metal) - clone + build if missing
if [ ! -x parakeet.cpp/build/examples/server/parakeet-server ]; then
  echo "==> building parakeet.cpp (Metal)..."
  [ -d parakeet.cpp ] || git clone --depth 1 https://github.com/mudler/parakeet.cpp
  ( cd parakeet.cpp \
    && git submodule update --init --recursive --depth 1 \
    && cmake -B build -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DPARAKEET_BUILD_CLI=ON -DPARAKEET_BUILD_SERVER=ON -DPARAKEET_GGML_METAL=ON \
    && cmake --build build -j )
fi

# 2. compile - link Sparkle only if the framework has been fetched (setup-sparkle.sh)
echo "==> compiling..."
mkdir -p build
SPARKLE_FLAGS=()
if [ -d "Frameworks/Sparkle.framework" ]; then
  echo "    (Sparkle framework found - enabling auto-update)"
  SPARKLE_FLAGS=(-F Frameworks -framework Sparkle
                 -Xlinker -rpath -Xlinker "@loader_path/../Frameworks")
fi
swiftc -O -target arm64-apple-macos13.0 Sources/main.swift -o "build/$BIN" \
  -framework AppKit -framework AVFoundation ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"}

# 3. assemble .app bundle
echo "==> bundling..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$BIN" "$APP/Contents/MacOS/$BIN"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f assets/MenuIcon.png ] && cp assets/MenuIcon.png "$APP/Contents/Resources/MenuIcon.png"
[ -f assets/MenuIconActive.png ] && cp assets/MenuIconActive.png "$APP/Contents/Resources/MenuIconActive.png"
if [ -d "Frameworks/Sparkle.framework" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Ghoasty</string>
  <key>CFBundleDisplayName</key><string>Ghoasty</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Akudama GmbH. All rights reserved.</string>
  <key>NSMicrophoneUsageDescription</key><string>Ghoasty records your voice so it can transcribe your speech on-device.</string>
  <key>SUFeedURL</key><string>$SU_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# 4. sign so macOS TCC (Accessibility, Mic) grants persist across rebuilds.
#    Prefer an Apple Development cert: it chains to Apple's root, so the code
#    requirement is cert+team based (stable) and a grant survives every rebuild.
#    A self-signed cert (WisprLiteDev) or ad-hoc pins the cdhash instead, so the
#    grant resets on each build - only a fallback when no Apple cert is present.
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
         | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
if [ -n "$DEV_ID" ]; then
  echo "==> signing with $DEV_ID (TCC grants persist across rebuilds)"
  codesign --force --deep -s "$DEV_ID" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "WisprLiteDev"; then
  echo "==> signing with WisprLiteDev (self-signed - TCC grants reset each rebuild)"
  codesign --force --deep -s "WisprLiteDev" "$APP"
else
  echo "==> ad-hoc signing (permissions won't persist)"
  codesign --force --deep -s - "$APP"
fi

echo "==> done: $PWD/$APP"
echo "Launch:  open $PWD/$APP"

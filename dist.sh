#!/bin/bash
# Build a self-contained, Developer-ID-signed, notarized, stapled Ghoasty.app + DMG.
# Prereq (one time): store notarization creds in the keychain, e.g.
#   xcrun notarytool store-credentials GhoastyNotary \
#     --apple-id hello@nightly.app --team-id ZTRDTUL87R --password <app-specific-password>
# Auto-update: run ./setup-sparkle.sh first (fetches Sparkle, generates keys).
# Then:  ./dist.sh            (set NOTARY_PROFILE=... if you named the profile differently)
#        SKIP_NOTARIZE=1 ./dist.sh   # sign + package only, no Apple round-trip
set -euo pipefail
cd "$(dirname "$0")"

ID="Developer ID Application: Akudama GmbH (ZTRDTUL87R)"
APP="Ghoasty.app"
DMG="Ghoasty.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-GhoastyNotary}"
GGML_SRC="parakeet.cpp/build/third_party/ggml/src"
SERVER_SRC="parakeet.cpp/build/examples/server/parakeet-server"
LIBS="libggml libggml-base libggml-cpu libggml-blas libggml-metal"

# 0. compile app + build parakeet.cpp (build.sh rebuilds the .app fresh each run).
#    The model is NOT bundled — the app downloads it on first run via onboarding.
./build.sh

# 1. vendor native deps into the bundle so it's relocatable
echo "==> vendoring native deps into $APP"
SERVER="$APP/Contents/Helpers/parakeet-server"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$SERVER_SRC" "$SERVER"
for l in $LIBS; do
  src=$(find "$GGML_SRC" -name "$l.0.dylib" | head -1)
  [ -n "$src" ] || { echo "!! missing $l.0.dylib"; exit 1; }
  cp -L "$src" "$APP/Contents/Frameworks/$l.0.dylib"   # deref symlink -> real file at @rpath name
done

# 2. rewrite rpaths: drop absolute build-tree paths, point at bundle-relative dirs
echo "==> fixing rpaths"
strip_abs_rpaths() {   # $1 = Mach-O file
  otool -l "$1" | awk '/LC_RPATH/{f=1;next} f&&/ path /{print $2;f=0}' | while read -r rp; do
    case "$rp" in
      /Users/*|*parakeet.cpp/build*) install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null || true ;;
    esac
  done
}
strip_abs_rpaths "$SERVER"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$SERVER"
for dy in "$APP"/Contents/Frameworks/*.dylib; do
  strip_abs_rpaths "$dy"
  install_name_tool -add_rpath "@loader_path" "$dy"     # dylibs cross-reference as @rpath/lib*.0.dylib
done
if otool -l "$SERVER" "$APP"/Contents/Frameworks/*.dylib | grep -q "parakeet.cpp/build"; then
  echo "!! absolute build-tree rpath still present"; exit 1
fi

# 3. sign inside-out with Developer ID + hardened runtime (nested first, bundle last; no --deep)
echo "==> signing"
SIGN=(codesign --force --options runtime --timestamp -s "$ID")
# 3a. Sparkle framework (sign nested helpers explicitly — Sparkle forbids --deep)
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  echo "    signing Sparkle.framework"
  V="$SPK/Versions/B"
  for x in "$V"/XPCServices/*.xpc; do [ -e "$x" ] && "${SIGN[@]}" "$x"; done
  [ -e "$V/Autoupdate" ]  && "${SIGN[@]}" "$V/Autoupdate"
  [ -e "$V/Updater.app" ] && "${SIGN[@]}" "$V/Updater.app"
  "${SIGN[@]}" "$SPK"
fi
# 3b. ggml dylibs
"${SIGN[@]}" "$APP"/Contents/Frameworks/*.dylib
# 3c. parakeet-server helper (with its entitlements)
codesign --force --options runtime --timestamp \
  --entitlements parakeet-server.entitlements -s "$ID" "$SERVER"
# 3d. outer app LAST (with app entitlements)
codesign --force --options runtime --timestamp \
  --entitlements Ghoasty.entitlements -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> SKIP_NOTARIZE set — signed but not notarized. Done: $PWD/$APP"
  exit 0
fi

# 4. notarize + staple the app
echo "==> notarizing app (uploads to Apple and waits)"
rm -f Ghoasty.zip
ditto -c -k --keepParent "$APP" Ghoasty.zip
xcrun notarytool submit Ghoasty.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f Ghoasty.zip

# 5. package DMG, notarize + staple it too
echo "==> building $DMG"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ghoasty" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# 6. update the Sparkle appcast for auto-updates.
#    Versioned DMGs accumulate in releases/ so generate_appcast can build the
#    version history (and binary deltas). It signs each DMG with the EdDSA
#    private key in the login keychain and writes releases/appcast.xml.
#    Upload the whole releases/ folder to the bucket behind $SU_FEED_URL.
GEN="Frameworks/bin/generate_appcast"
if [ -x "$GEN" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  echo "==> updating appcast (version $VER, build $BUILD)"
  mkdir -p releases
  cp "$DMG" "releases/Ghoasty-$VER.dmg"
  "$GEN" --download-url-prefix "https://updates.ghoasty.ai/" releases/
  echo "    appcast: $PWD/releases/appcast.xml"
  echo "    To publish (upload DMG + appcast to R2): ./publish.sh"
else
  echo "==> Sparkle not set up (run ./setup-sparkle.sh) — skipping appcast"
fi

echo "==> done"
echo "    App: $PWD/$APP  (stapled)"
echo "    DMG: $PWD/$DMG  (stapled, ready to share)"
echo "Verify: spctl -a -vvv -t exec $APP  &&  xcrun stapler validate $DMG"

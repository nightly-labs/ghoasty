#!/bin/bash
# Publish the already-built Ghoasty release to the R2 bucket served at
# updates.ghoasty.ai (both the landing-page download and the Sparkle appcast).
# Run ./dist.sh first to produce the signed, notarized, stapled artifacts.
#
# One-time setup (wrangler already authenticated):
#   bunx wrangler r2 bucket create ghoasty-releases
#   then attach custom domain updates.ghoasty.ai to the bucket
#   (Cloudflare dashboard -> R2 -> ghoasty-releases -> Custom Domains).
set -euo pipefail
cd "$(dirname "$0")"

BUCKET="ghoasty-releases"
APP="Ghoasty.app"
DMG="Ghoasty.dmg"

# 0. artifacts must exist (produced by ./dist.sh)
[ -f "$DMG" ] || { echo "!! $DMG missing — run ./dist.sh first"; exit 1; }
[ -d "$APP" ] || { echo "!! $APP missing — run ./dist.sh first"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
VDMG="releases/Ghoasty-$VER.dmg"
APPCAST="releases/appcast.xml"
[ -f "$VDMG" ]    || { echo "!! $VDMG missing — run ./dist.sh first"; exit 1; }
[ -f "$APPCAST" ] || { echo "!! $APPCAST missing — run ./setup-sparkle.sh then ./dist.sh"; exit 1; }

# wrangler r2 object put keys are bucket/key; --remote hits real R2 (not the local sim).
# Use the repo-pinned wrangler via bun from web/.
put() {  # $1=key  $2=file  $3=content-type  $4=cache-control
  echo "==> uploading $1"
  ( cd web && bunx wrangler r2 object put "$BUCKET/$1" \
      --file "../$2" --remote \
      --content-type "$3" --cache-control "$4" )
}

# 1. stable "latest" for the landing page — short cache so new ships propagate fast
put "$DMG"              "$DMG"     "application/x-apple-diskimage" "public, max-age=300, must-revalidate"
# 2. immutable versioned archive (Sparkle enclosures point here)
put "Ghoasty-$VER.dmg" "$VDMG"    "application/x-apple-diskimage" "public, max-age=31536000, immutable"
# 3. Sparkle appcast — short cache so clients see new versions promptly
put "appcast.xml"      "$APPCAST" "application/xml"               "public, max-age=300, must-revalidate"

echo "==> published version $VER"
echo "    Download: https://dl.ghoasty.ai/$DMG"
echo "    Appcast:  https://updates.ghoasty.ai/appcast.xml"

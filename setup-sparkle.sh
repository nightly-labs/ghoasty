#!/bin/bash
# One-time Sparkle setup for auto-updates:
#   1. downloads the Sparkle framework into ./Frameworks (git-ignored)
#   2. generates an EdDSA signing key pair (private key stored in your login keychain)
#   3. prints the public key to paste into build.sh (SU_PUBLIC_ED_KEY)
# After this, build.sh / dist.sh link + embed Sparkle automatically.
set -euo pipefail
cd "$(dirname "$0")"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
TARBALL="Sparkle-$SPARKLE_VERSION.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/$TARBALL"

mkdir -p Frameworks
if [ ! -d "Frameworks/Sparkle.framework" ]; then
  echo "==> downloading Sparkle $SPARKLE_VERSION"
  tmp=$(mktemp -d)
  curl -L --fail -o "$tmp/$TARBALL" "$URL"
  tar -xf "$tmp/$TARBALL" -C "$tmp"
  cp -R "$tmp/Sparkle.framework" Frameworks/
  # keep the helper tools (generate_keys, sign_update) next to the framework
  [ -d "$tmp/bin" ] && cp -R "$tmp/bin" Frameworks/bin
  rm -rf "$tmp"
  echo "    Sparkle.framework -> Frameworks/"
fi

GEN="Frameworks/bin/generate_keys"
[ -x "$GEN" ] || GEN="Frameworks/Sparkle.framework/Versions/B/Resources/generate_keys"
echo "==> generating / reading EdDSA key (private key lives in the login keychain)"
"$GEN" || true          # no-op if a key already exists
echo
echo "Public key (copy into build.sh -> SU_PUBLIC_ED_KEY):"
"$GEN" -p
echo
echo "Next:"
echo "  1. paste the public key above into build.sh (SU_PUBLIC_ED_KEY=...)"
echo "  2. set SUFeedURL in build.sh to your real appcast URL"
echo "  3. ./dist.sh   (builds the signed, notarized DMG with auto-update enabled)"
echo "  4. sign each release for the appcast:  Frameworks/bin/sign_update Ghoasty.dmg"

#!/usr/bin/env bash
# Build the fork, stamp commit + build number into Info.plist, codesign,
# and install over /Applications/Ghostty Fork.app.
# See FORK_CHANGES.md → "Building" for what each step does and why.
set -euo pipefail

cd "$(dirname "$0")/.."

# xcodebuild reuses macos/build/ across runs and codesigns the bundle *inside*
# `zig build`. If any resource-fork / Finder-info detritus lands in that output
# dir (e.g. a stray "Icon\r" custom-icon file from a Finder "paste icon"), that
# internal codesign bails with "resource fork, Finder information, or similar
# detritus not allowed" before we ever reach our own signing below. Scrub it.
if [ -d macos/build ]; then
  find macos/build -name $'Icon\r' -delete 2>/dev/null || true
  xattr -cr macos/build 2>/dev/null || true
fi

/opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast

plist=zig-out/Ghostty.app/Contents/Info.plist
commit=$(git rev-parse --short HEAD)
build=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $commit" "$plist"
/usr/libexec/PlistBuddy -c "Add :GhosttyCommit string $commit" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $commit" "$plist"

# Sign with the stable self-signed identity if it exists, so the Accessibility
# (TCC) grant survives rebuilds; otherwise fall back to ad-hoc. The cert-based
# designated requirement is identity-based rather than CDHash-based, so the
# grant isn't invalidated by a new build. See scripts/01-setup-signing-cert.sh.
sign_identity="Ghostty Fork Local"
if security find-identity -p codesigning | grep -qF "$sign_identity"; then
  sign_arg="$sign_identity"
else
  echo "warning: code-signing identity '$sign_identity' not found; using ad-hoc" >&2
  echo "         (run ./scripts/01-setup-signing-cert.sh so Accessibility grants persist)" >&2
  sign_arg="-"
fi
# Strip extended attributes (resource forks / Finder info) that otherwise make
# codesign bail with "resource fork, Finder information, or similar detritus".
xattr -cr zig-out/Ghostty.app
codesign --force --deep -s "$sign_arg" \
  -o runtime \
  --entitlements macos/GhosttyReleaseLocal.entitlements \
  zig-out/Ghostty.app
rm -rf "/Applications/Ghostty Fork.app"
cp -R zig-out/Ghostty.app "/Applications/Ghostty Fork.app"

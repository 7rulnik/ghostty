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

# Compiling the Metal shaders needs Xcode's Metal Toolchain, which is a
# separate on-demand download as of Xcode 26. Without it `zig build` dies deep
# in the dependency tree with a hard-to-place xcrun error, so say it up front.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "error: Xcode's Metal Toolchain is missing; shader compilation will fail." >&2
  echo "       Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

# Ghostty pins the Zig it builds with in build.zig.zon and enforces it at
# comptime (see src/build/zig.zig `requireZig`). Read that pin and resolve a
# matching binary instead of hardcoding a path: Homebrew's `zig` floats to the
# newest release, and /opt/homebrew/opt/zig@X.Y is usually just a versioned
# alias into that same keg rather than an independent pin, so any fixed path
# rots the moment either side moves. See FORK_CHANGES.md.
zig_want=$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)
if [ -z "$zig_want" ]; then
  echo "error: could not read .minimum_zig_version from build.zig.zon" >&2
  exit 1
fi

# Mirror requireZig's comparison: major.minor must match *exactly* (0.17 is
# rejected just like 0.15), while the patch may be newer than the pin.
zig_ok() {
  local have base patch
  have=$("$1" version 2>/dev/null) || return 1
  base=${have%%-*}  # 0.16.0-dev.42+abcdef -> 0.16.0
  base=${base%%+*}
  [ "${base%.*}" = "${zig_want%.*}" ] || return 1
  patch=${base##*.}
  case $patch in '' | *[!0-9]*) return 1 ;; esac
  [ "$patch" -ge "${zig_want##*.}" ]
}

# $ZIG wins, then whatever is on PATH (so a version manager or direnv shim gets
# a say), then Homebrew's kegs as a fallback.
zig_bin=""
for candidate in \
  ${ZIG:-} \
  "$(command -v zig || true)" \
  "/opt/homebrew/opt/zig@${zig_want%.*}/bin/zig" \
  /opt/homebrew/opt/zig/bin/zig; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  zig_ok "$candidate" || continue
  zig_bin="$candidate"
  break
done

if [ -z "$zig_bin" ]; then
  echo "error: no Zig ${zig_want%.*}.x (>= $zig_want) found; build.zig.zon requires it." >&2
  echo "       Homebrew's 'zig' formula tracks the latest release, so it may have" >&2
  echo "       moved past the pin. Try 'brew install zig@${zig_want%.*}', or point" >&2
  echo "       ZIG at a matching binary: ZIG=/path/to/zig $0" >&2
  echo "       See FORK_CHANGES.md -> 'Keeping Zig in sync'." >&2
  exit 1
fi

echo "building with $zig_bin ($("$zig_bin" version), pin ${zig_want})"
"$zig_bin" build -Doptimize=ReleaseFast

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

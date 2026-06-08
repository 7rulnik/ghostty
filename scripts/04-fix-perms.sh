#!/usr/bin/env bash
# Reset the Accessibility grant for the fork so `global:` keybinds work
# again after a rebuild (CDHash changes invalidate the grant).
# See FORK_CHANGES.md → "Accessibility permission" for the full story.
set -euo pipefail

osascript -e 'tell application "Ghostty Fork" to quit' 2>/dev/null || true

# `tccutil reset` deletes the grant row from the TCC database — the same row
# the `−` button removes — so old steps 1 & 2 are now automatic.
tccutil reset Accessibility dev.v7rulnik.ghostty

# Jump straight to the Accessibility pane (old step 1).
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# Warn if the bundle is ad-hoc signed: then this grant won't survive the next
# rebuild. Run scripts/01-setup-signing-cert.sh + rebuild to make it persistent.
if codesign -dvv "/Applications/Ghostty Fork.app" 2>&1 | grep -q "Signature=adhoc"; then
  echo "WARNING: 'Ghostty Fork.app' is ad-hoc signed — this grant will break on"
  echo "         the next rebuild. Run ./scripts/01-setup-signing-cert.sh, then"
  echo "         ./scripts/03-build.sh, to sign with a stable identity first."
  echo
fi

cat <<'EOF'
Next steps (one-time with a stable signing identity):
  1. Launch Ghostty Fork; accept the Accessibility prompt.
  2. Toggle the freshly-added entry on. Retry timer picks it up in ~1s.

The TCC reset already removed any stale entry, and the Accessibility pane
should be open. If a leftover 'Ghostty Fork' row somehow remains, select it
and click − before relaunching.
EOF

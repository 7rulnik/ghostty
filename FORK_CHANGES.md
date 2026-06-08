# Fork changes

This is a personal fork of [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
with a handful of patches that aren't (yet) upstream. Branch:
[`fork-main`](https://github.com/7rulnik/ghostty/tree/fork-main).

## Separate configs for stock and fork

Both apps coexist with different bundle IDs (`com.mitchellh.ghostty` vs.
`dev.v7rulnik.ghostty`). Ghostty's config loader reads files in this
order — later files override earlier ones:

1. **`~/.config/ghostty/config`** — shared XDG config. Both apps read
   this. Put any settings you want for *both* installs here.
2. **`~/Library/Application Support/<bundle-id>/config`** — per-bundle
   override. Each install reads only its own.

Concrete paths:

| App | Per-bundle config |
|---|---|
| Stock Ghostty | `~/Library/Application Support/com.mitchellh.ghostty/config` |
| Ghostty Fork  | `~/Library/Application Support/dev.v7rulnik.ghostty/config` |

The per-bundle file is created the first time the app launches (with a
helpful comment-only template). Anything you put there overrides the
shared XDG config for that install only.

Example — give stock the paper icon while leaving the fork on default:

```fish
echo 'macos-icon = paper' \
  >> ~/Library/Application\ Support/com.mitchellh.ghostty/config
```

Reload via the in-app "Reload Configuration" keybind, or quit and
relaunch the app whose config you changed.

### Auto-updates

Sparkle drives stock's auto-updater. The fork is built locally, so
Sparkle shouldn't try to update it (it would only fail to install over
your own build, or worse, replace the fork with a stock release).

Stock — pull every tip commit, auto-download, notify:

```ini
# ~/Library/Application Support/com.mitchellh.ghostty/config
auto-update = download
auto-update-channel = tip
```

(Use `auto-update-channel = stable` for tagged releases only.)

Fork — disable updates entirely:

```ini
# ~/Library/Application Support/dev.v7rulnik.ghostty/config
auto-update = off
```

Restart each app once for the change to take effect (Sparkle initializes
on launch). To pull new fork code, re-run the build commands above.

## Pulling upstream updates

Two remotes are configured: `origin` (this fork) and `upstream`
(ghostty-org/ghostty).

### Rebase target: the `tip` tag, not `upstream/main`

Ghostty's [`release-tip.yml`][1] workflow force-moves a `tip` git tag
to the SHA of every `main` commit that produces a successful tip
release (Test workflow green, macOS build + notarize succeed). It's
the same SHA that backs the "Ghostty Tip (Nightly)" GitHub release,
the Sparkle appcast, and `tip.files.ghostty.org`.

So the `tip` tag is the latest *known-good, releasable* upstream
commit, while `upstream/main` may be ahead of it with commits that
haven't been built or have failing CI. Rebasing the fork onto `tip`
keeps it aligned with what stock Ghostty users on
`auto-update-channel = tip` are actually running.

```fish
./scripts/02-rebase.sh
```

The script runs `git fetch upstream --tags --force`, checks out
`fork-main`, rebases onto `tip`, and force-pushes. `--tags --force` is
required because upstream rewrites the `tip` tag on every release;
without `--force` git refuses to update a local tag that's diverged.

Rebase (vs. merge) keeps the fork's patches sitting cleanly on top of
upstream — no merge bubbles. The cost is `--force-with-lease` rewriting
the remote `fork-main`. Safe for a personal fork.

[1]: https://github.com/ghostty-org/ghostty/blob/main/.github/workflows/release-tip.yml

If `git rebase` hits conflicts (likely if upstream touches files this
fork edits — `Termio.zig`, `Surface.zig`, `Ghostty.App.swift`,
`MainMenu.xib`, the asset catalog, etc.):

```fish
# git pauses with a conflict; edit the files, then:
git add <files>
git rebase --continue

# or bail out:
git rebase --abort
```

After a successful rebase, rebuild + reinstall (see [Building](#building)).

## Building

One-time setup:

```fish
# Full Xcode (not just Command Line Tools — the Metal compiler ships with Xcode)
sudo xcode-select -s /Applications/Xcode.app

# Xcode 26+ delivers the Metal toolchain as a separate component (~700 MB)
xcodebuild -downloadComponent MetalToolchain

# Zig 0.15.x (this repo's minimum_zig_version pins 0.15.2)
brew install zig@0.15
```

Build + install (release):

```fish
./scripts/03-build.sh
```

The script runs `zig build -Doptimize=ReleaseFast`, stamps the real
commit + build number into Info.plist (so the About window shows them
instead of the hardcoded "Version 0.1 / Build 1" from the Xcode
project; must happen before codesign because editing the plist
invalidates the signature), codesigns the bundle with Hardened Runtime
and the local entitlements, then installs over `/Applications/Ghostty
Fork.app`.

The `-o runtime` flag enables Hardened Runtime and `--entitlements`
embeds the privacy + library-validation entitlements the repo ships.
Without these, the ad-hoc-signed bundle can register global hotkeys
(so `toggle_visibility` can hide) but macOS rejects the activation
call needed to bring the app back from hidden state — the toggle
becomes one-way. `GhosttyReleaseLocal.entitlements` includes
`com.apple.security.cs.disable-library-validation`, which Hardened
Runtime requires here because the bundled `GhosttyKit.xcframework`
isn't signed with a matching identity.

For faster iteration, omit `-Doptimize=ReleaseFast` (debug build is the
default and links significantly faster). The debug bundle is the same
path, just slower at runtime.

The bundle ID is `dev.v7rulnik.ghostty` (release) / `dev.v7rulnik.ghostty.debug`
(debug), so the fork coexists with the stock Ghostty install at
`/Applications/Ghostty.app`. Display name is "Ghostty Fork" so Spotlight,
Dock, and Cmd+Tab tell them apart.

If you ever see `Launchd job spawn failed` (POSIX 162) after an
incremental rebuild, the adhoc signature is stale — re-run the
`codesign` command above.

### Version info in the About window

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`macos/Ghostty.xcodeproj/project.pbxproj` are hardcoded to `0.1` and
`1`, so an unpatched local build's About window says exactly that. The
PlistBuddy calls in the build recipe stamp three keys after
`zig build` but before `codesign`:

- `CFBundleVersion` → `git rev-list --count HEAD` (monotonic build
  number, matching upstream CI's convention).
- `CFBundleShortVersionString` → `git rev-parse --short HEAD`. The
  About view (`AboutView.swift:22-29`) regex-matches the value: a 7–40
  char hex string is treated as a tip release, so the Version row
  renders "Tip Release" rather than the raw hash.
- `GhosttyCommit` → same short hash. The About view renders this as a
  clickable Commit row linking to
  `github.com/ghostty-org/ghostty/commits/<hash>`.

Caveat: the Commit link is hardcoded to the upstream repo
(`AboutView.swift:6`). A fork-local commit that hasn't been pushed to
upstream will 404 — fine in practice because `fork-main` is rebased
onto the upstream `tip` tag, so the patched commits are the only ones
that won't resolve, and you know which ones those are.

If you'd rather keep "Version 0.1" (or any custom string) and just
add the commit row, drop the `CFBundleShortVersionString` line — the
About view's "other" branch renders an arbitrary string verbatim.

### Accessibility permission (for `global:` keybinds)

`global:` keybinds use a `CGEventTap`, which requires Accessibility
permission. TCC keys this by bundle ID + code signature, so the grant
for stock Ghostty (`com.mitchellh.ghostty`) does **not** transfer to
the fork (`dev.v7rulnik.ghostty`), and re-signing invalidates a prior
grant.

Symptom when it's missing: `global:cmd+grave_accent=toggle_visibility`
hides the window (local key handler still fires when focused) but
doesn't bring it back (only the global event tap can deliver the
press when the app is hidden).

To confirm the grant isn't being honored:

```fish
/usr/bin/log stream --predicate 'subsystem == "dev.v7rulnik.ghostty"' --info --debug --style compact
```

If you see `creating global event tap failed, missing permissions?`
retried every second, the grant isn't being honored.

One-time grant procedure (assumes stable signing — see below):

1. Run `./scripts/04-fix-perms.sh` — quits Ghostty Fork, runs `tccutil
   reset Accessibility dev.v7rulnik.ghostty` (which removes any stale
   list entry — old manual "remove the row" step is now automatic), and
   opens the Accessibility pane.
2. Relaunch `Ghostty Fork`. The Accessibility prompt should appear;
   click "Open System Settings" and toggle the freshly-added entry on.
3. The fork's retry timer picks up the new permission within a second
   — no second relaunch needed.

With a stable signing identity this is genuinely one-time: it survives
every subsequent rebuild.

### Stable signing so the grant survives rebuilds

TCC stores the *designated requirement* (DR) of the binary it granted.
With ad-hoc signing (`codesign -s -`) the DR is pinned to the CDHash:

```
designated => cdhash H"54dafe…" or cdhash H"cd9ff0…"
```

Every `zig build` + `codesign` produces a new CDHash, so the DR no
longer matches and the grant is silently invalidated (the requirement
check fails with `SecStaticCodeCheckValidity status -67050` even though
the UI shows the toggle as on) — and `global:` keybinds break again
with the same one-way `toggle_visibility` symptom.

The fix is to sign with a **stable self-signed certificate** instead of
ad-hoc. Run once:

```bash
./scripts/01-setup-signing-cert.sh
```

This generates a self-signed code-signing cert named `Ghostty Fork
Local` in the login keychain (OpenSSL 3.x needs the `-legacy` PKCS#12
format for Apple's importer; the key is imported with `-A` so `codesign`
can use it without a prompt). `scripts/03-build.sh` then signs with that
identity automatically (falling back to ad-hoc with a warning if the
cert is missing). The DR becomes identity-based and constant:

```
designated => identifier "dev.v7rulnik.ghostty" and certificate root = H"2b193c…"
```

Because the cert (hence its root hash) is the same on every build, the
DR is stable and the Accessibility grant persists across rebuilds. The
cert is untrusted (`CSSMERR_TP_NOT_TRUSTED`), which is fine: the DR is
satisfied by a cert-hash match, not anchor trust, and locally-built,
non-quarantined apps run regardless. (A real Apple Developer ID would
also work and additionally allow notarization, but isn't needed here.)

After running the setup once, do the one-time grant procedure above
(the switch from ad-hoc to cert-signed changes the identity, so the old
ad-hoc grant must be reset once). From then on, rebuilds keep the grant.

## 1. cmd+click on `path:line:col` jumps to the line

Compiler and linter output commonly emits paths shaped like
`src/foo.ts:42:10`. Upstream's URL detector already matches these, but
the resolver tries to `accessAbsolute` the literal string (including the
`:42:10` suffix), finds nothing, and falls back to handing the raw
match to the system opener — which silently fails.

This fork:

- Retries path resolution with a trailing `:line[:col]` suffix stripped
  if the literal path doesn't exist on disk. A file that legitimately
  contains `:N[:M]` in its name still wins (literal attempt is tried
  first).
- Adds a `link-open-template` config option for substituting `{path}`,
  `{line}`, `{col}` into a URL (e.g.
  `cursor://file/{path}:{line}:{col}`).
- On macOS, when `link-open-template` is empty, the apprt auto-detects
  the default app for the file's extension. If it registers a VS Code
  family URL scheme (`vscode`, `vscode-insiders`, `vscodium`, `codium`,
  `cursor`, `windsurf`, `positron`, `trae`), the open is routed through
  `<scheme>://file/<abs>:<line>:<col>` so the editor jumps to the
  matched location. Otherwise the suffix is stripped and the bare file
  opens normally.

Result: in a terminal sitting at a project root, cmd+click on
`spa-entry/redirects_table/table.ts:806:5` opens that file at line 806,
col 5 in whichever VS Code-family editor handles `.ts`.

### Config

```ini
# Optional. When unset on macOS, the editor URL scheme is auto-detected
# via LaunchServices. Set explicitly to override:
link-open-template = cursor://file/{path}:{line}:{col}
```

## 2. Find / search UX aligned with macOS conventions

Upstream's search overlay works but follows a navigation model where
"next" walks toward older matches (upward through the scrollback). For
users coming from VS Code, Chrome, or other macOS apps, Cmd+G is
expected to advance *forward* (downward, toward newer matches).

This fork:

- **Cmd+G / Cmd+Shift+G** advance forward / backward respectively,
  matching the macOS Find convention. Works whether the search field
  or the surface has focus.
- **Enter / Shift+Enter** in the search field follow the same
  convention.
- **Hold-to-repeat** works for Enter and Cmd+G in the search field
  (backported `onKeyPress` now accepts a `phases` option, the find
  handlers use `[.down, .repeat]`).
- **Counter** displays `1` for the topmost match and `N` for the
  bottom-most, matching how users read the buffer top-to-bottom.
  Internally Ghostty numbers from the bottom; the SwiftUI label
  inverts at display.
- Wrapping at the ends was already implemented in the search engine
  upstream; no engine change needed.

Also fixes a small bug where `findPrevious` in `BaseTerminalController`
was wired to call `findNext`, so the Find Previous menu item now
actually goes to the previous match.

## 3. Cmd+K unconditionally clears everything

Upstream's `clear_screen` action has an "at-prompt" heuristic that only
fires when shell integration markers are present on the cursor row. In
practice (multi-line starship prompts, custom `fish_prompt`, etc.) the
markers don't always land where the heuristic expects, so Cmd+K
sometimes only erases lines above the cursor — leaving the current
prompt where it was and lots of empty rows above.

This fork's `Termio.clearScreen`:

- Always clears the scrollback.
- Always clears the visible area (via `eraseDisplay(.complete)`), then
  clears the scrollback **again** because `.complete` has a Kitty-style
  heuristic that scrolls visible content into the scrollback when it
  thinks it's at a prompt.
- Parks the cursor at (1, 1).
- Sends a form feed so the shell repaints.

There is one fish-side gotcha: fish 4's default `Ctrl-L` binding wraps
`clear-screen` with a `scrollback-push` when the terminal advertises
the `scroll-content-up` feature (`xterm-ghostty` does). That pushes the
visible content into scrollback as a "soft clear", undoing the wipe.
The fix is in your fish config, not Ghostty:

```fish
# ~/.config/fish/config.fish
bind \cl clear-screen
```

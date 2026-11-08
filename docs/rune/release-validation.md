# DockShift 0.3.0 validation

Validated November 8, 2026 on the Apple silicon MacBook Air running macOS 27.2.
Version 0.3.0 uses build number 3 and pins Rune to
`a7f276c3630f85a06a0230295da4d2bd172d8d3b`.

## Interface and engine

- Sixteen Rune interaction tests passed. They cover navigation, profile commands, modal
  isolation, drafts, Unicode composition, clipboard operations, Command-arrow navigation,
  refreshed Dock selections, app movement and scroll reachability.
- Five wallpaper regression checks passed against the production reconciler with service
  doubles. These verify capturing all originals before a global wallpaper write, requesting
  verification after a new unconfirmed write, avoiding an endless verification loop,
  discarding ownership after a rejected write, and restoring an unassigned visible desktop
  after a hidden desktop changes the shared wallpaper.
- Twenty-six updater configuration checks passed across Release and Debug compilation modes.
- Both independent review passes were triaged. All nine findings were accepted and fixed;
  none were dismissed. The final pass added rejected-write ownership cleanup, modified
  text-editing commands and native Edit menu actions.
- Native UI checks exercised profile creation with Return, renaming, deletion, copy/cut/paste,
  Dock reordering with saved-file verification, wallpaper placement, scrolling, both themes,
  the menu popover and native window appearance. Shift-arrow selection, Option-Backspace
  word deletion and the native Edit menu's Select All, Cut and Paste actions also passed.
- Actual Dock/wallpaper switching and Restore Original were checked on two desktops. The
  shared-wallpaper baseline problem was reproduced and retested after the fix.
- A first rapid-switching attempt produced a transient Dock verification failure. The
  automatic retry recovered; the controlled follow-up completed successfully.
- The locally installed Rune build opened the user's real profile. All eleven existing
  profile/settings/original files retained their hashes after installation.
- Screenshots in this directory render sample profiles through Rune. Every main page, dialogs,
  the compact layout and the menu panel were visually inspected during development. Actual
  native window captures and a four-second motion demo are in the ignored review artifacts.

Run `scripts/test-rune.sh`, `scripts/test-wallpapers.sh` and `scripts/test-updates.sh` to repeat
the automated checks. `scripts/run-rune-preview.sh` opens a paused, disposable native preview.

## Distribution

- The application executable and embedded Rune dylib contain both arm64 and x86_64 slices.
- Developer ID archive/export and deep strict signature verification passed.
- Apple accepted application submission `dcf2e1b9-4e02-4b41-8171-02a9a8cdfe52` and disk-image
  submission `5cbf96d2-ddac-47ec-ab6b-273dd09c5a10`. The final artifacts were stapled.
- The app extracted from the final ZIP passed ticket validation and Gatekeeper assessment
  with source `Notarized Developer ID`.
- The disk image was mounted read-only. Its app passed signature, ticket and Gatekeeper
  checks, and its Applications link was present.
- Sparkle verified the signed appcast. Independent CryptoKit verification accepted the ZIP
  signature with the embedded public key and rejected modified ZIP bytes.
- The appcast specifies version 0.3.0/build 3, the exact ZIP length and the immutable
  `v0.3.0` GitHub download URL. The permanent public key and feed URL match released 0.2.0.
- All final DMG, ZIP and appcast checksums passed.

Publication must retain the signed appcast's exact bytes and mark v0.3.0 as the latest stable
release. The public-feed installation is checked after publication.

## Limits

The Intel slices compiled and were inspected but were not executed on an Intel Mac. System
Settings Focus-filter activation was not repeated for this UI rewrite. Rune is prerelease;
the dependency is pinned to a specific commit.

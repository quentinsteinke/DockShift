# Updater validation on the MacBook Air

Tested November 6, 2026 on an Apple M5 MacBook Air with 24 GB RAM, macOS 27.2, build 26B123.
The starting commit is `fe882079184a2d62e1f74fbd51f728ec6be6d132`. GitHub main matched that commit
when checked before release preparation.

## Passed

- Universal Debug and Release builds with Apple Development signing. Both contain `x86_64` and
  `arm64` executable slices, embedded Sparkle and App Intents metadata.
- `codesign --verify --deep --strict` on both final builds and the installed update fixture.
- Thirteen configuration checks in each of Release and Debug compilation modes. Release rejects
  HTTP even for the test bundle. Debug permits HTTP only for the fixture at `127.0.0.1`.
- Real DockShift UI displayed an automatic update offer from a signed local feed.
- Dismissing the offer left the old version installed.
- Turning automatic checks off still allowed a manual check.
- Modifying the signed appcast caused the visible error that the feed could not be validated.
- Flipping a byte in the ZIP without changing its length caused the visible archive-signature error.
  Build 1 and all eight seeded data files remained unchanged after the rejected update.
- Restoring the valid signed archive allowed download, verification, Install and Relaunch, and an
  automatic relaunch into version 0.2.0, build 2. Settings displayed the new version.
- The installed executable matched the signed update payload byte-for-byte.
- All eight seeded data files remained byte-for-byte identical across installation and relaunch.
  These include two profile Dock snapshots, config with two profiles, a wallpaper image, original
  Dock and wallpaper records, state, and the empty wallpaper-slot list.
- The relaunched app retained the automatic-check preference as off and the paused setting as on.
- The preserved profile opened in the UI with its name, saved Dock and wallpaper preview intact.
- Checking again showed the up-to-date result for 0.2.0.
- Stopping the local feed server showed a recoverable update error.
- All eleven existing files under the user's actual DockShift data directory matched their
  recorded hashes after testing.
- Shell/Python syntax checks, `git diff --check`, and release preflight rejection without signing
  configuration passed. The build helper also built the Release configuration successfully.

The test copies use bundle identifier `com.quentinsteinke.DockShift.UpdaterTest` and isolated
storage under `/tmp`. The feed server bound only to loopback. The server and test application were
stopped after testing. Test signing keys stayed in mode-0600 temporary files and were not printed
or added to the repository. The Release executable contains neither test storage override string.

Build logs and configuration-test output are under `build/validation/`, which Git ignores.
The repeatable setup, configuration checks and hash verification live in `scripts/` and `tests/`.

## Final release verified

The complete release helper finished successfully with Developer ID signing and
`NOTARY_PROFILE=DockShift`. Apple accepted both submissions with no issues:

- Application: `91225fe7-4c24-4c96-9d36-73bf4807b6e0`.
- DMG: `8c4a3223-3ad9-4f1d-ab12-69fe85835a25`.

The final four files are saved under `build/release-0.2.0/`: `DockShift-0.2.0.zip`,
`DockShift-0.2.0.dmg`, `appcast.xml` and `SHA256SUMS.txt`. The original preparation output is at
`/tmp/DockShift-ready-release-0.2.0`. The release log and Apple's acceptance reports are saved under
`build/validation/`. Both directories in the checkout are Git-ignored.

All final checksums passed, including after copying the artifacts into the workspace. Sparkle
verified the final signed feed. Its build number is 2, its version is 0.2.0, its enclosure length
matches the ZIP, and its download URL is the versioned GitHub release URL. An independent CryptoKit
check using the embedded permanent public key accepted the final ZIP signature and rejected
modified archive bytes.

The final ZIP was extracted with `ditto`. Deep strict code-signature verification, update
configuration validation, both architecture checks and notarization-ticket validation passed.
Gatekeeper accepted it with source `Notarized Developer ID`. The final DMG's ticket validated.
It was mounted read-only; its app also passed deep strict signature verification, ticket validation
and Gatekeeper assessment. The Applications link was present and the image was detached afterward.

## Remaining work and limits

The prepared artifacts target stable GitHub release `v0.2.0`. This first updater-enabled release
must be installed manually by existing users; subsequent releases use the in-app flow. Secure
backup of the permanent signing keys remains an owner-controlled step. No private key was exported
for backup.

The installation test used writable disposable copies. Privileged replacement in `/Applications`
and installation during a live Dock/wallpaper switch remain untested.

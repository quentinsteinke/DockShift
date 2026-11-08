# Update release setup

DockShift uses Sparkle 2.10.1, pinned in `project.yml`. It requires an Ed25519-signed appcast and
checks each archive's signature before extraction. Automatic checks run daily. Installation always
requires the user's choice. Sparkle handles the download, application replacement and relaunch.

The app stores profiles outside its bundle, so replacing the application does not replace its data.
Before a relaunch, DockShift finishes any Dock apply already in progress, cancels queued work, waits
for wallpaper work to stop and saves remembered Dock edits. This does not change the Pause setting.

## One-time setup

1. DockShift's permanent signing key now exists in this Air's login Keychain under account
   `DockShift`. Its public key is in `Config/Updates.xcconfig`. Use Sparkle's
   `generate_keys --account DockShift -p` to check that public key without exporting the private key.
2. Back up the private key securely using Sparkle's documented key export process. Keep the backup
   outside this repository. Losing the key can prevent existing installations from trusting updates.
3. The Air now has the valid **Developer ID Application: Quentin Steinke (8C5LBVCRXP)** identity.
   Its private key stays in the login Keychain. Developer ID archive/export and signature checks
   passed. Use this identity for distribution.
4. The Air has a validated `notarytool` Keychain profile named `DockShift`, using the approved
   Developer-role team key named `DockShift Notarization`. Private credentials stay outside the
   repository. Use `NOTARY_PROFILE=DockShift` on this Mac.

The feed URL is `https://github.com/quentinsteinke/DockShift/releases/latest/download/appcast.xml`.
The configured public key enables the updater. An update feed will be available after the first
authorized updater-enabled release is published. Source builds with a missing or invalid public
key keep updates disabled and explain that in Settings. Test keys must never ship.

Official reference: [Sparkle setup and signing](https://sparkle-project.org/documentation/).

## Prepare a release

Increase both `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION` in `project.yml`.
Sparkle compares build numbers, so every published update needs a larger build number.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notary-profile' \
scripts/release.sh
```

The script checks that the embedded public key matches the signing key in the `DockShift` Keychain
account. It archives both architectures, exports with Developer ID signing for the nested Sparkle
helpers, verifies the bundle, notarizes and staples it, then creates
the final ZIP, DMG, signed `appcast.xml` and `SHA256SUMS.txt`. It writes a new output directory and
refuses to overwrite an existing one. Build output defaults to `/tmp` so iCloud metadata cannot
invalidate nested framework signatures. Set `SPARKLE_BIN` if the Sparkle tools are elsewhere.

After reviewing and authorizing publication, create GitHub release `v<version>` and attach those
four files. Make it the latest stable release. Keep `appcast.xml` byte-for-byte unchanged after
signing. Its ZIP URL includes the immutable version tag. Publishing source commits alone does not
create an update offer. This script does not push tags, create releases or upload assets.

The old v0.1.0 app cannot discover the updater. Users need one manual installation of the first
updater-enabled release. Future releases use the in-app flow.

## Local macOS tests

Run `scripts/test-updates.sh` for configuration checks, including rejection of HTTP, file URLs,
embedded credentials, missing or invalid keys, and missing signature requirements.

`scripts/prepare-update-fixture.sh` builds two disposable copies with the real DockShift UI and
Sparkle, versions 0.1.0 and the current project version. It generates a separate test key in a mode-0600 file under `/tmp`,
signs a local feed and verifies it. It does not change the permanent Keychain key. Each run needs a
new `UPDATE_TEST_ROOT` directory, and it refuses to overwrite an existing installed fixture.

Only Debug builds with bundle identifier `com.quentinsteinke.DockShift.UpdaterTest` accept a feed
over HTTP at `127.0.0.1`. That bundle always uses `/tmp/DockShift-UpdaterTest-<username>` for data,
including after Sparkle relaunches it. Release builds have neither exception. A Debug build may
also use `DOCKSHIFT_TEST_DATA_DIRECTORY` for other isolated UI tests.

Seed paused test profiles with `python3 tests/seed-update-fixture.py` before launching. The seed
script refuses existing data. Its manifest records the hashes of config, Dock snapshots, wallpaper
and original files. Then serve the feed on loopback, open the installed fixture and use Settings to
check for updates. Compare the data manifest and the installed build number after relaunch.

Also test a modified signed feed, a modified archive, no newer version, network failure, dismissal,
automatic-check preference persistence, and a manual check after turning automatic checks off.
Production Gatekeeper and notarization tests require the permanent key and Developer ID artifacts.

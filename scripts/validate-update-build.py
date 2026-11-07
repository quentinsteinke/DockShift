#!/usr/bin/env python3
"""Fail a distribution build before packaging if it cannot safely receive updates."""
import base64
import pathlib
import plistlib
import sys
import urllib.parse

app = pathlib.Path(sys.argv[1])
def require(condition, message):
    if not condition:
        raise SystemExit(message)

with (app / 'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
require(info['CFBundleIdentifier'] == 'com.quentinsteinke.DockShift', 'Wrong application identity')
require(info['CFBundleVersion'].isdigit() and int(info['CFBundleVersion']) > 1, 'Increment the build number')
require(info['SUPublicEDKey'] == sys.argv[2], 'Embedded public key differs from release signing key')
key = base64.b64decode(info['SUPublicEDKey'], validate=True)
require(len(key) == 32 and any(key), 'Configure a valid permanent public key')
feed = urllib.parse.urlsplit(info['SUFeedURL'])
require(feed.scheme == 'https' and feed.hostname and not feed.username and not feed.password, 'HTTPS feed required')
require(info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction'], 'Signature enforcement missing')
require(not info['SUAutomaticallyUpdate'] and not info['SUAllowsAutomaticUpdates'], 'Updates must ask first')
require((app / 'Contents/Frameworks/Sparkle.framework').is_dir(), 'Sparkle is missing')
print('Update distribution configuration verified')

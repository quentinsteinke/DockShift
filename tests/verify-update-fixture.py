#!/usr/bin/env python3
"""Verify the installed update and byte-for-byte preservation of the seeded app data."""
import getpass
import hashlib
import json
import os
import pathlib
import plistlib

root = pathlib.Path(os.environ.get('UPDATE_TEST_ROOT', '/tmp/DockShift-updater-e2e'))
app = root / 'installed/DockShift.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
expected = plistlib.loads((root / 'new/DockShift.app/Contents/Info.plist').read_bytes())
if info['CFBundleVersion'] != expected['CFBundleVersion'] or info['CFBundleShortVersionString'] != expected['CFBundleShortVersionString']:
    raise SystemExit('The installed test app has not updated to the prepared version')
if (app / 'Contents/MacOS/DockShift').read_bytes() != (root / 'new/DockShift.app/Contents/MacOS/DockShift').read_bytes():
    raise SystemExit('Installed executable differs from the signed test payload')
data = pathlib.Path('/tmp') / ('DockShift-UpdaterTest-' + getpass.getuser())
before = json.loads((root / 'data-before.json').read_text())
after = {str(p.relative_to(data)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in data.rglob('*') if p.is_file()}
if before != after:
    raise SystemExit('Test profile data changed during the update')
print(f"PASS: installed build {info['CFBundleVersion']} matches the update; all {len(after)} data files preserved")

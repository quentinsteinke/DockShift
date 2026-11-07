#!/usr/bin/env python3
"""Create paused profile data for the Debug-only UpdaterTest bundle. Refuses existing data."""
import datetime
import getpass
import hashlib
import json
import os
import pathlib
import plistlib
import shutil

root = pathlib.Path('/tmp') / ('DockShift-UpdaterTest-' + getpass.getuser())
assert not root.exists(), f'Existing test data retained: {root}'
for directory in ('Docks', 'Wallpapers', 'Original'):
    (root / directory).mkdir(parents=True, exist_ok=True)
ids = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222']
profiles = []
for index, profile_id in enumerate(ids):
    profile = dict(id=profile_id, name=['Default', 'Updater preservation test'][index], isDefault=index == 0,
                   hasDock=True, dockRevision=7, createdAt='2026-11-06T00:00:00Z')
    if index:
        profile['wallpaper'] = dict(fileName='fixture.png', displayName='Preserved picture', placement='Crop',
                                    fillColor=dict(red=0, green=0, blue=0))
    profiles.append(profile)
    snapshot = dict(persistentApps=plistlib.dumps([], fmt=plistlib.FMT_BINARY),
                    persistentOthers=plistlib.dumps([], fmt=plistlib.FMT_BINARY),
                    capturedAt=datetime.datetime(2026, 11, 6), osVersion='test')
    (root / 'Docks' / (profile_id + '.plist')).write_bytes(plistlib.dumps(snapshot, fmt=plistlib.FMT_BINARY))
(root / 'config.json').write_text(json.dumps(dict(version=1, profiles=profiles, spaceAssignments={},
    settings=dict(paused=True, rememberDockEdits=True, desktopDockDwell=2.5))))
(root / 'state.json').write_text(json.dumps(dict(appliedDockOK=False)))
(root / 'wallpaper-slots.json').write_text('{}')
(root / 'Original' / 'wallpaper.json').write_text('{"capturedAt":"2026-11-06T00:00:00Z"}')
shutil.copyfile(root / 'Docks' / (ids[0] + '.plist'), root / 'Original' / 'dock.plist')
shutil.copyfile('DockShift/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png', root / 'Wallpapers' / 'fixture.png')
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}
fixture = pathlib.Path(os.environ.get('UPDATE_TEST_ROOT', '/tmp/DockShift-updater-e2e'))
fixture.mkdir(parents=True, exist_ok=True)
(fixture / 'data-before.json').write_text(json.dumps(manifest, indent=2))
print(f'Created {len(manifest)} fixture data files at {root}; app starts paused')

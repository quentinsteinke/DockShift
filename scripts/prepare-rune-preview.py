#!/usr/bin/env python3
"""Seed disposable, paused data for the separately identified Debug Rune preview app."""
import datetime
import json
import pathlib
import plistlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
assets = pathlib.Path(sys.argv[2])
if root.exists():
    raise SystemExit(f"Existing preview retained: {root}")
for directory in ("Docks", "Wallpapers", "Original"):
    (root / directory).mkdir(parents=True, exist_ok=True)
apps = [
    ("Finder", "/System/Library/CoreServices/Finder.app"),
    ("Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
    ("Notes", "/System/Applications/Notes.app"),
    ("Calendar", "/System/Applications/Calendar.app"),
    ("Messages", "/System/Applications/Messages.app"),
    ("Mail", "/System/Applications/Mail.app"),
]
profiles = []
for i, (name, asset, indices) in enumerate([
    ("Everyday", "11-wallpaper-coast.png", range(6)),
    ("Deep work", "12-wallpaper-dusk.png", range(3)),
    ("After hours", "13-wallpaper-clay.png", range(2, 6)),
]):
    profile_id = f"{i + 1:08d}-1111-4111-8111-111111111111"
    wallpaper = f"preview-{i}.png"
    shutil.copyfile(assets / asset, root / "Wallpapers" / wallpaper)
    profiles.append(dict(id=profile_id, name=name, isDefault=i == 0, hasDock=True,
        dockRevision=1, createdAt="2026-11-08T00:00:00Z", wallpaper=dict(fileName=wallpaper,
        displayName=["Coastal morning", "Blue hour", "Warm horizon"][i], placement="Crop",
        fillColor=dict(red=0, green=0, blue=0))))
    tiles = [{"tile-type": "file-tile", "tile-data": {
        "file-label": apps[j][0], "file-data": {"_CFURLString": pathlib.Path(apps[j][1]).as_uri(), "_CFURLStringType": 15}, "file-type": 41}}
        for j in indices]
    snapshot = dict(persistentApps=plistlib.dumps(tiles, fmt=plistlib.FMT_BINARY),
        persistentOthers=plistlib.dumps([], fmt=plistlib.FMT_BINARY),
        capturedAt=datetime.datetime(2026, 11, 8), osVersion="UI preview fixture")
    (root / "Docks" / f"{profile_id}.plist").write_bytes(plistlib.dumps(snapshot, fmt=plistlib.FMT_BINARY))
(root / "config.json").write_text(json.dumps(dict(version=1, profiles=profiles,
    spaceAssignments={}, settings=dict(paused=True, rememberDockEdits=True, desktopDockDwell=1.2))))
(root / "state.json").write_text(json.dumps(dict(appliedDockOK=False)))
(root / "wallpaper-slots.json").write_text("{}")
print(f"Paused Rune preview data created at {root}")

#!/usr/bin/env python3
"""Inspect an official Are.na ZIP without extracting files or making requests.

Prints aggregate structure only, never block titles, descriptions, IDs, or URLs.
Usage: python3 scripts/inspect-arena-export.py /path/to/channel.zip
"""
import csv
import io
import json
import plistlib
import sys
from collections import Counter
from pathlib import PurePosixPath
from zipfile import ZipFile


def inspect(path):
    with ZipFile(path) as archive:
        files = [item for item in archive.infolist() if not item.is_dir()]
        manifests = [item for item in files if item.filename.lower().endswith('.csv')]
        if len(manifests) != 1:
            raise ValueError('Expected exactly one CSV manifest')
        manifest = manifests[0]
        if manifest.file_size > 20 * 1024 * 1024:
            raise ValueError('Manifest exceeds inspection limit')
        reader = csv.DictReader(io.StringIO(archive.read(manifest).decode('utf-8-sig')))
        rows = list(reader)
        if not {'ID', 'Filename'}.issubset(reader.fieldnames or []):
            raise ValueError('Manifest is missing ID or Filename')
        names = set(archive.namelist())
        shortcuts = [item for item in files if item.filename.lower().endswith('.webloc')]
        invalid_shortcuts = 0
        for item in shortcuts:
            if item.file_size > 1024 * 1024:
                raise ValueError('Shortcut exceeds inspection limit')
            try:
                payload = plistlib.loads(archive.read(item))
                if not isinstance(payload, dict) or not isinstance(payload.get('URL'), str):
                    invalid_shortcuts += 1
            except Exception:
                invalid_shortcuts += 1
        # This verifies compressed bytes only. It does not execute or extract content.
        if sum(item.file_size for item in files) > 1024 * 1024 * 1024:
            raise ValueError('Archive exceeds 1 GiB inspection limit')
        crc_ok = archive.testzip() is None
        return {
            'file_count': len(files),
            'uncompressed_bytes': sum(item.file_size for item in files),
            'extensions': dict(sorted(Counter(PurePosixPath(item.filename).suffix.lower() for item in files).items())),
            'manifest_columns': reader.fieldnames,
            'manifest_rows': len(rows),
            'unique_manifest_ids': len({row['ID'] for row in rows}),
            'manifest_file_matches': sum(row['Filename'] in names for row in rows),
            'shortcut_count': len(shortcuts),
            'invalid_shortcut_plists': invalid_shortcuts,
            'archive_crc_ok': crc_ok,
        }


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(json.dumps(inspect(sys.argv[1]), indent=2))

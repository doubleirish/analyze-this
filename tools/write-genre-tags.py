"""Write the library's canonical genres (the analyze-this database) back into the audio files' tags.

    python tools\\write-genre-tags.py            # dry run: shows what would change
    python tools\\write-genre-tags.py --apply    # writes tags, keeps a backup JSON

Only songs with their own genre are written (not ones inheriting from artist or
album) and "Unknown" is never written. After each write the file's modified
time is restored and the stored sizes (database row, .bpm and .wave sidecars)
are updated, so a rescan sees an unchanged file and nothing is re-analysed.
Supports mp3, m4a, flac, ogg. Close analyze-this first. Needs: pip install mutagen
"""
import argparse
import json
import os
import re
import sqlite3
import struct
import subprocess
import sys
import time

import mutagen
from mutagen.id3 import ID3

EXTS = {'.mp3', '.m4a', '.flac', '.ogg'}


def app_running():
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq analyze_this.exe'],
                         capture_output=True, text=True).stdout
    return 'analyze_this.exe' in out


def patch_bpm(path, old, new):
    p = path + '.bpm'
    if not os.path.exists(p):
        return
    with open(p, encoding='utf-8') as f:
        t = f.read()
    t2 = re.sub(r'("fileSize"\s*:\s*)%d\b' % old, lambda m: m.group(1) + str(new), t)
    if t2 != t:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(t2)


def patch_wave(path, old, new):
    p = path + '.wave'
    if not os.path.exists(p):
        return
    with open(p, 'r+b') as f:
        head = f.read(36)
        if len(head) < 36 or head[:4] != b'BWV1':
            return
        if int(struct.unpack('>d', head[12:20])[0]) == old:
            f.seek(12)
            f.write(struct.pack('>d', float(new)))


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--db', default=os.path.join(
        os.environ.get('APPDATA', ''), 'com.example', 'analyze_this', 'analyze_this.db'))
    ap.add_argument('--backup', default='genre-tags-backup-%s.json' % time.strftime('%Y%m%d-%H%M%S'))
    a = ap.parse_args()

    if a.apply and app_running():
        sys.exit('Close analyze-this first.')
    db = sqlite3.connect(a.db)
    rows = db.execute(
        "SELECT path, genre, size FROM songs "
        "WHERE genre IS NOT NULL AND genre != '' AND genre != 'Unknown' AND genre_src IS NULL").fetchall()

    todo, errors, backup = 0, 0, {}
    for path, genre, size in rows:
        if os.path.splitext(path)[1].lower() not in EXTS or not os.path.exists(path):
            continue
        try:
            f = mutagen.File(path, easy=True)
            if f is None or f.tags is None:
                continue
            cur = list(f.tags.get('genre', []))
            if cur == [genre]:
                continue
            todo += 1
            print('%s: %s -> %s   %s' % ('write' if a.apply else 'would', cur, genre, path))
            if not a.apply:
                continue
            st = os.stat(path)
            backup[path] = cur
            v3 = False
            if path.lower().endswith('.mp3'):
                try:
                    v3 = ID3(path).version < (2, 4, 0)
                except Exception:
                    pass
            f.tags['genre'] = [genre]
            f.save(v2_version=3) if v3 else f.save()
            new_size = os.path.getsize(path)
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
            if new_size != st.st_size:
                patch_bpm(path, st.st_size, new_size)
                patch_wave(path, st.st_size, new_size)
            db.execute('UPDATE songs SET size = ? WHERE path = ?', (new_size, path))
        except Exception as e:
            errors += 1
            print('ERROR %s: %s' % (path, e))

    if a.apply:
        db.commit()
        if backup:
            with open(a.backup, 'w', encoding='utf-8') as f:
                json.dump(backup, f, indent=1)
            print('Old tag values saved to', a.backup)
    print('%s %d file(s), %d error(s)%s' % ('Changed' if a.apply else 'Would change', todo, errors,
                                            '' if a.apply else ' (run with --apply)'))


main()

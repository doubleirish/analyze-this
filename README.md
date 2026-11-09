# analyze-this

Library analytics, metadata acquisition and mixtape (playlist) building/play-testing.
Owns the database, scanner, enrichment, discography and planner code.
Playback and shared analysis live in `../shared_core`; the companion player is `../beats-me`.

    flutter pub get && flutter test && flutter run -d windows

## Features

- **Mix building**: auto-fill RPM-based class programs with smooth tempo ordering,
  artist spacing and best-fit closing songs; lock songs and re-fill single parts;
  import M3U/M3U8 playlists.
- **Class programs**: built-in and generated programs place the half & half in the
  middle and a ~2 min recovery after every second activity (about 1 min when two or
  fewer activities are left before the cool-down, none after the last). The "Generate…" wizard lets you
  drag activities to reorder them, and drag (or "+") activities in from a list; part
  lengths are re-fitted so the class keeps its length.
- **Fill rules**: a part ends where a song ends, within ±60 s of its target. When one song cannot do it, fill prefers two songs of similar length and tempo over one long song plus a very short one.
- **Mix safety**: undo/redo (Ctrl+Z / Ctrl+Y), unsaved-changes prompts, and the
  working mix is restored after a restart.
- **Saved mixes manager**: search (name, program, tag), sort (name, saved, last opened, last taught, length), length filter, list or grid view, pinned and archived mixes, tags, a per-mix icon (pick a symbol and colour, or use the album-art collage), duplicate, rename, and multi-select bulk pin, tag, archive and delete (delete has Undo). The icon travels to the phone with the mix.
- **Class history**: "Mark as taught", plus suggestions detected from play history
  (PC or phone). Songs taught in the last N weeks (default 6) can be hidden and are
  avoided by fill, swap and suggestions.
- **Library**: BPM fixes (½×, 2×, set value or tap tempo) that survive rescans;
  quick scan on startup (Folders tab toggle); decade filters built from the library.
- **Insights**: program readiness per part (candidates, needed, fresh) and RPM-band
  coverage per role; class sheet with cue lists, print layout and "Open in browser".
- **Phone sync**: beats-me plays and ratings come back to the PC over Wi-Fi (after a
  send, or "Sync plays & ratings from phone") or USB ("Sync from phone (USB)").
- **Album ownership lookup**: Tools > Share > "Send album list to phone" sends
  artist, album and owned/total track counts over paired Wi-Fi or USB, without
  copying audio. The mix Send dialog also has "Send album list"; the list updates
  automatically on Wi-Fi/USB journal sync and individual mix sends.
  In beats-me, **Own it?** searches this snapshot offline. Track gaps, missing
  discs and tag totals flag incomplete albums. Unknown totals are not proof of
  completeness; no online catalogue is consulted. Rescan all your music roots
  first: this reflects database records, not a fresh check of files on disk.
  Untagged albums are omitted and edition names stay distinct. USB confirms
  delivery to the inbox only; open beats-me and allow storage access to import.
- **Damaged audio**: every library scan quick-checks new or changed files (MP3 frame
  walk; FLAC/OGG/WAV/M4A container sizes) and tags damaged ones `corrupt`. Tools ›
  Damaged audio runs a full quick check or a deep ffmpeg decode (tolerates up to 3
  isolated decode errors and ignores broken cover art). Damaged songs are never
  suggested or auto-filled and can't be added by hand; in a mix they show a badge and
  a Replace button (closest length and tempo) plus "Replace all" (undoable). Saved
  mixes show a damaged count, and Send warns before sending. "Plays fine" (or
  removing the tag) overrides a flag until the file changes.
- **Song settings**: trim a song's start/end (the trimmed length is what fills and
  filters use), mark or unmark it explicit (overrides the lyrics check), and Tools ›
  Measure loudness so the phone can level volume between songs. All survive rescans.
- **Clean class**: a Mix toolbar chip; fills, suggestions and replacements never pick
  explicit songs, and Send warns about any left in the mix.
- **Cues**: a note per song in a mix (e.g. "stand on the chorus"). Notes travel with the
  mix; the phone shows them on Now Playing and in class mode and can speak them.
- **Keeping classes fresh**: *Rotation* (toolbar chip) never picks songs used in the
  last N other saved mixes; *Refresh* previews and swaps recently used songs for
  close stand-ins in one undo step; *Plan series…* fills and saves 2–12 mixes of the
  program ("Name 1"…) that avoid each other's songs, tagged `series:Name`.
- **Energy graph**: the tempo profile above the mix shows song width by length and
  in/off-band colour. Hover or tap a song to see it and jump to it in the list;
  drag it sideways to reorder within its activity.
- **Filters per activity**: Auto-fill › each activity's filter shows how many songs
  fit each tempo band and what removes the rest (filter, explicit/rating, rotation),
  in orange or red when supply runs low. Limits carried from the Songs tab, Clean class
  and rotation show as chips.
- **Backup & restore**: Tools › Back up now / Restore from file…; an automatic daily
  backup keeps the newest five. Restores are checked (schema, SQLite) and applied at
  the next start.
- **Shortcuts**: Space play/pause, Ctrl+S save, Ctrl+F search, Ctrl+1…6 switch tabs.
- **Batch send**: Mix tab › "Send folder to phone…" picks a folder of `.beatsmix`
  files and sends the ticked ones to a USB / Wi-Fi-debugging phone with adb, with
  progress and per-file results (a failed file doesn't stop the rest).

## Scripts (`tools\`)

    # Export every saved mix as a .beatsmix file (ids kept, so the phone updates in place)
    tools\export-saved-mixes.ps1 -OutDir D:\music [-Name 'Techno*']

    # Send every .beatsmix in a folder to the phone over adb
    tools\send-beatsmix.ps1 -Dir D:\music [-Filter 'Techno*'] [-Serial <id>]
    tools\send-beatsmix.ps1 -Setup        # how to install adb and set up the phone

    # Pre-flight: find corrupt files and formats Android can't play (e.g. .wma)
    tools\check-audio.ps1 -Path D:\music\Coldplay [-Name '*Clocks*']
    tools\check-audio.ps1 -Path D:\music -Beatsmix

    # Convert tracks Android can't play (.wma etc.) inside .beatsmix files to AAC
    # (originals backed up to <Dir>_backup_audiofix); then re-send with send-beatsmix.ps1
    tools\fix-beatsmix-audio.ps1 -Dir D:\music

    # Install .beatsmix files into the local Windows beats-me app (its Mixtapes folder)
    tools\import-beatsmix-local.ps1 -Dir D:\music [-Root D:\music\Mixtapes]

    # 60-minute mixes for the top genres and artists (a different class style
    # each, no similar activities side by side); then import or send them
    tools\build-top-mixes.ps1 -OutDir D:\music [-Count 10]

    # Genres: the app merges near-duplicates (Electro/Electronica -> Electronic)
    # and turns junk into "Unknown" at startup. Also write them into the files'
    # tags (dry run unless --apply; close the app first; backs up old values):
    python tools\write-genre-tags.py [--apply]

    # No cable/adb: serve a folder over Wi-Fi and print an ASCII QR code.
    # On the phone: beats-me > Mixtapes > Scan QR code.
    tools\serve-phone-qr.ps1 -Dir D:\music [-Name 'Techno*']

`send-beatsmix.ps1` prints setup help when adb or a ready phone is missing.
Mixes pulled via QR are stored as `pull:<id>` on the phone, a separate copy
from the `zip:<id>` ones sent over adb. The PC firewall must allow the printed
TCP port on the Private network.

`export-saved-mixes.ps1` reads a copy of the database, so the app can stay open.
Saved mixes opened for the first time get a new mixtape id; open and save a mix
(or send it once from the app) to keep its id stable.

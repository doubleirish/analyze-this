import 'dart:convert';

import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'genre_names.dart';
import 'tempo_stats.dart';
import 'song_models.dart';

export 'song_models.dart';

String _like(String s) => '%${s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';

class MusicDb {
  MusicDb._(this._db);

  /// SQL for [Song.playSeconds].
  static const _playSql = '(COALESCE(trim_end, duration) - COALESCE(trim_start, 0))';
  final Database _db;

  static Future<MusicDb> open(String path) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 20, onCreate: _create, onUpgrade: _upgrade),
    );
    return MusicDb._(db);
  }

  static Future<void> _create(Database db, int v) async {
    await db.execute('CREATE TABLE folders(path TEXT PRIMARY KEY)');
    await db.execute('''CREATE TABLE songs(
      path TEXT PRIMARY KEY, size INTEGER, mtime INTEGER, title TEXT, artist TEXT,
      album TEXT, year INTEGER, genre TEXT, duration REAL, avg_bpm REAL,
      median_bpm REAL, min_bpm REAL, max_bpm REAL, bpm_stddev REAL, lyrics TEXT,
      lyrics_checked INTEGER DEFAULT 0, mb_checked INTEGER DEFAULT 0,
      rating INTEGER DEFAULT 0, explicit INTEGER DEFAULT 0, dup_key TEXT,
      fav INTEGER DEFAULT 0, added_at INTEGER)''');
    await db.execute('''CREATE TABLE segments(
      path TEXT, start REAL, "end" REAL, bpm REAL)''');
    await db.execute('CREATE INDEX seg_path ON segments(path)');
    await db.execute('''CREATE TABLE song_tags(
      path TEXT, tag TEXT, PRIMARY KEY(path, tag))''');
    await db.execute('CREATE TABLE mixes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, saved_at INTEGER)');
    await db.execute('''CREATE TABLE mix_items(
      mix_id INTEGER, pos INTEGER, path TEXT, part INTEGER, PRIMARY KEY(mix_id, pos))''');
    await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    await _createV4(db);
    await _createV5(db);
    await _createV6(db);
    await _createV7(db);
    await _createV8(db);
    await _createV9(db);
    await _createV10(db);
    await _createV11(db);
    await _createV12(db);
    await _createV13(db);
    await _createV15(db);
    await _createV16(db);
    await _createV17(db);
    await _createV18(db);
    await _createV19(db);
    await _createV20(db);
  }

  static Future<void> _createV20(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS online_cache(
      key TEXT PRIMARY KEY, payload TEXT, attempted_at INTEGER NOT NULL, error TEXT)''');
  }

  /// Whether a year lookup already ran (separate from the genre lookup's mb_checked).
  static Future<void> _createV19(Database db) async {
    final have = {for (final r in await db.rawQuery('PRAGMA table_info(songs)')) r['name'] as String};
    if (!have.contains('year_checked')) {
      await db.execute('ALTER TABLE songs ADD COLUMN year_checked INTEGER DEFAULT 0');
    }
  }

  /// Artist folders a full scan finished (see [saveScanDir]), so later scans
  /// can skip them. `done_ops` is a bit set of `ScanOps`.
  static Future<void> _createV18(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS scan_dirs(
      dir TEXT PRIMARY KEY, root TEXT, fingerprint TEXT,
      done_ops INTEGER DEFAULT 0, completed_at INTEGER)''');
  }

  /// Loudness, trim points, the user's explicit mark, last-mixed date, and
  /// per-song notes in saved mixes.
  static Future<void> _createV17(Database db) async {
    final have = {for (final r in await db.rawQuery('PRAGMA table_info(songs)')) r['name'] as String};
    for (final (c, type) in const [
      ('loudness', 'REAL'),
      ('trim_start', 'REAL'),
      ('trim_end', 'REAL'),
      ('explicit_manual', 'INTEGER'),
      ('last_mixed', 'INTEGER'),
    ]) {
      if (!have.contains(c)) await db.execute('ALTER TABLE songs ADD COLUMN $c $type');
    }
    final items = {for (final r in await db.rawQuery('PRAGMA table_info(mix_items)')) r['name'] as String};
    if (!items.contains('note')) await db.execute('ALTER TABLE mix_items ADD COLUMN note TEXT');
  }

  /// Mix management: icon (`MixIconSpec.encode`), pin, archive, last opened,
  /// free-form tags, and an index for "which mixes use this song".
  static Future<void> _createV16(Database db) async {
    for (final col in ['icon TEXT', 'pinned INTEGER DEFAULT 0', 'archived INTEGER DEFAULT 0', 'last_opened INTEGER']) {
      try {
        await db.execute('ALTER TABLE mixes ADD COLUMN $col');
      } on DatabaseException catch (e) {
        if (!e.toString().contains('duplicate column')) rethrow;
      }
    }
    await db.execute('''CREATE TABLE IF NOT EXISTS mix_tags(
      mix_id INTEGER, tag TEXT, PRIMARY KEY(mix_id, tag))''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_mix_tags_tag ON mix_tags(tag)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_mix_items_path ON mix_items(path)');
  }

  /// Damage-check results (see [recordHealth]); keyed by size+mtime so a
  /// re-ripped or repaired file is checked again.
  static Future<void> _createV15(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS song_health(
      path TEXT PRIMARY KEY, size INTEGER, mtime INTEGER, status TEXT,
      reason TEXT, depth TEXT, checked_at INTEGER)''');
  }

  /// Class history: each taught class with a snapshot of its songs, so later
  /// edits to the mix don't rewrite history. Idempotent (see v14 in [_upgrade]).
  static Future<void> _createV11(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS class_sessions(
      id INTEGER PRIMARY KEY AUTOINCREMENT, mix_id INTEGER, mix_name TEXT,
      taught_at INTEGER, source TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS class_session_items(
      session_id INTEGER, pos INTEGER, path TEXT, PRIMARY KEY(session_id, pos))''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_class_session_items_path ON class_session_items(path)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_class_sessions_mix ON class_sessions(mix_id, taught_at)');
  }

  /// Files sent to phones in mixtape packages, so phone plays can be matched
  /// back by content hash.
  static Future<void> _createV13(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS sent_tracks(
      sha256 TEXT PRIMARY KEY, path TEXT, sent_at INTEGER)''');
  }

  /// Manual BPM fix (see [setBpmFix]): exactly one of bpm_scale / bpm is set.
  static Future<void> _createV12(Database db) async {
    final have = {for (final r in await db.rawQuery('PRAGMA table_info(overrides)')) r['name'] as String};
    for (final c in ['bpm_scale', 'bpm']) {
      if (!have.contains(c)) await db.execute('ALTER TABLE overrides ADD COLUMN $c REAL');
    }
  }

  static Future<void> _createV10(Database db) async {
    for (final (name, on) in const [
      ('idx_songs_median_bpm', 'songs(median_bpm)'),
      ('idx_songs_artist', 'songs(artist)'),
      ('idx_songs_genre', 'songs(genre)'),
      ('idx_songs_dup_key', 'songs(dup_key)'),
      ('idx_songs_added_at', 'songs(added_at)'),
      ('idx_mix_items_path', 'mix_items(path)'),
      ('idx_song_tags_tag', 'song_tags(tag)'),
    ]) {
      await db.execute('CREATE INDEX IF NOT EXISTS $name ON $on');
    }
  }

  static Future<void> _createV9(Database db) async {
    await db.execute('ALTER TABLE mixes ADD COLUMN program TEXT');
  }

  static Future<void> _createV8(Database db) async {
    await db.execute('''CREATE TABLE best_of(
      artist TEXT, pos INTEGER, path TEXT, PRIMARY KEY(artist, pos))''');
  }

  static Future<void> _createV7(Database db) async {
    for (final c in ['track_no', 'track_total', 'disc_no', 'disc_total']) {
      await db.execute('ALTER TABLE songs ADD COLUMN $c INTEGER');
    }
    await db.execute('ALTER TABLE songs ADD COLUMN tags_v INTEGER DEFAULT 0');
  }

  static Future<void> _createV6(Database db) async {
    await db.execute('''CREATE TABLE plays(
      id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT, played_at INTEGER,
      listened REAL, completed INTEGER DEFAULT 0, app TEXT)''');
    await db.execute('CREATE INDEX plays_path ON plays(path)');
  }

  static Future<void> _createV5(Database db) async {
    await db.execute('ALTER TABLE songs ADD COLUMN genre_src TEXT');
    await db.execute('CREATE TABLE artist_genres(key TEXT PRIMARY KEY, name TEXT, genre TEXT)');
    await db.execute(
      'CREATE TABLE album_genres(key TEXT PRIMARY KEY, artist TEXT, album TEXT, genre TEXT, source TEXT)',
    );
  }

  static Future<void> _createV4(Database db) async {
    await db.execute('CREATE TABLE smart_lists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, json TEXT)');
    await db.execute('''CREATE TABLE overrides(
      path TEXT PRIMARY KEY, artist TEXT, album TEXT, genre TEXT, year INTEGER)''');
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE songs ADD COLUMN bpm_stddev REAL');
      await db.execute('ALTER TABLE songs ADD COLUMN rating INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE songs ADD COLUMN explicit INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE songs ADD COLUMN dup_key TEXT');
      await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    }
    if (from < 3) {
      await db.execute('ALTER TABLE mix_items ADD COLUMN part INTEGER');
    }
    if (from < 4) {
      await db.execute('ALTER TABLE songs ADD COLUMN fav INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE songs ADD COLUMN added_at INTEGER');
      await db.execute('ALTER TABLE mixes ADD COLUMN saved_at INTEGER');
      await _createV4(db);
    }
    if (from < 5) await _createV5(db);
    if (from < 6) await _createV6(db);
    if (from < 7) await _createV7(db);
    if (from < 8) await _createV8(db);
    if (from < 9) await _createV9(db);
    if (from < 10) await _createV10(db);
    if (from < 11) await _createV11(db);
    if (from < 12) await _createV12(db);
    if (from < 13) await _createV13(db);
    // v11 landed after v12/v13 had shipped to dev databases, so a DB already at
    // 12 or 13 skipped it; v14 re-runs the (idempotent) v11 step to catch up.
    if (from < 14) await _createV11(db);
    if (from < 15) await _createV15(db);
    if (from < 16) await _createV16(db);
    if (from < 17) await _createV17(db);
    if (from < 18) await _createV18(db);
    if (from < 19) await _createV19(db);
    if (from < 20) await _createV20(db);
  }

  Future<void> close() => _db.close();

  Future<(String?, int, String?)?> onlineCache(String key) async {
    final rows = await _db.query('online_cache', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return (r['payload'] as String?, r['attempted_at'] as int, r['error'] as String?);
  }

  Future<void> saveOnlineCache(String key, String? payload, int attemptedAt, {String? error}) => _db.insert(
    'online_cache',
    {'key': key, 'payload': payload, 'attempted_at': attemptedAt, 'error': error},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  // ---- settings ----

  Future<String?> setting(String key) async {
    final r = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) =>
      _db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<String>> explicitWords() async {
    final v = await setting('explicit_words');
    if (v == null) return [...defaultExplicitWords];
    return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Saves the word list and re-flags every song with lyrics.
  Future<void> saveExplicitWords(List<String> words) async {
    await setSetting('explicit_words', words.join(','));
    final rows = await _db.query('songs', columns: ['path', 'lyrics'], where: "lyrics IS NOT NULL AND lyrics <> ''");
    await _db.transaction((t) async {
      for (final r in rows) {
        await t.update(
          'songs',
          {'explicit': containsExplicit(r['lyrics'] as String?, words) ? 1 : 0},
          where: 'path = ?',
          whereArgs: [r['path']],
        );
      }
    });
  }

  // ---- folders ----

  Future<List<String>> folders() async => [
    for (final r in await _db.query('folders', orderBy: 'path')) r['path'] as String,
  ];

  Future<void> addFolder(String p) => _db.insert('folders', {'path': p}, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> removeFolder(String p) async {
    await _db.delete('folders', where: 'path = ?', whereArgs: [p]);
    await _db.delete('scan_dirs', where: 'root = ?', whereArgs: [p]);
  }

  // ---- finished artist folders (incremental full scans) ----

  /// Fingerprint and finished-work bits of every remembered folder.
  Future<Map<String, (String, int)>> scanDirs() async => {
    for (final r in await _db.query('scan_dirs', columns: ['dir', 'fingerprint', 'done_ops']))
      r['dir'] as String: ((r['fingerprint'] as String?) ?? '', (r['done_ops'] as int?) ?? 0),
  };

  Future<void> saveScanDir(String dir, String root, String fingerprint, int doneOps) => _db.insert('scan_dirs', {
    'dir': dir,
    'root': root,
    'fingerprint': fingerprint,
    'done_ops': doneOps,
    'completed_at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Forgets these folders so the next full scan looks at them again.
  Future<void> forgetScanDirs(Iterable<String> dirs) async {
    for (final c in _chunks(dirs.toSet().toList())) {
      await _db.delete('scan_dirs', where: 'dir IN (${_marks(c.length)})', whereArgs: c);
    }
  }

  /// Forgets every folder under these library roots.
  Future<void> clearScanDirs(Iterable<String> roots) async {
    for (final c in _chunks(roots.toSet().toList())) {
      await _db.delete('scan_dirs', where: 'root IN (${_marks(c.length)})', whereArgs: c);
    }
  }

  /// What a full scan needs to decide, per file, whether any work is left
  /// (no lyrics text, so it stays small for big libraries). An inherited
  /// genre (album/artist list) is left out, as [Scanner.processLocal] does.
  Future<Map<String, Song>> scanSnapshot() async {
    final rows = await _db.query(
      'songs',
      columns: [
        'path',
        'size',
        'mtime',
        'title',
        'artist',
        'album',
        'year',
        'genre',
        'genre_src',
        'duration',
        'median_bpm',
        'lyrics',
        'lyrics_checked',
        'mb_checked',
        'year_checked',
        'tags_v',
      ],
    );
    return {
      for (final r in rows) r['path'] as String: Song.fromRow(r['genre_src'] == null ? r : {...r, 'genre': null}),
    };
  }

  /// Size and mtime each file had at its last damage check.
  Future<Map<String, (int, int)>> healthStamps() async => {
    for (final r in await _db.query('song_health', columns: ['path', 'size', 'mtime']))
      r['path'] as String: ((r['size'] as int?) ?? -1, (r['mtime'] as int?) ?? -1),
  };

  // ---- songs ----

  Future<Song?> song(String path) async {
    final r = await _db.query('songs', where: 'path = ?', whereArgs: [path]);
    return r.isEmpty ? null : Song.fromRow(r.first, await tagsOf(path));
  }

  /// Stores a scanned song; the user-owned columns (trim, explicit mark,
  /// last mixed) of an existing row are kept.
  Future<void> upsertSong(Song s, {List<TempoSeg> segments = const []}) => upsertSongs([(s, segments)]);

  Future<void> upsertSongs(List<(Song, List<TempoSeg>)> songs) => _db.transaction((t) async {
    final batch = t.batch();
    for (final (s, segments) in songs) {
      final row = s.toRow(user: false);
      final cols = row.keys.toList();
      batch.rawInsert(
        'INSERT INTO songs (${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')}) '
        'ON CONFLICT(path) DO UPDATE SET ${[for (final c in cols)
          if (c != 'path') '$c = excluded.$c'].join(', ')}',
        [for (final c in cols) row[c]],
      );
      batch.delete('segments', where: 'path = ?', whereArgs: [s.path]);
      for (final g in segments) {
        batch.insert('segments', {'path': s.path, 'start': g.start, 'end': g.end, 'bpm': g.bpm});
      }
    }
    await batch.commit(noResult: true);
  });

  Future<void> deleteSongs(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    await _db.transaction((t) async {
      final batch = t.batch();
      for (final p in list) {
        for (final table in ['songs', 'segments', 'song_tags', 'overrides', 'best_of', 'song_health']) {
          batch.delete(table, where: 'path = ?', whereArgs: [p]);
        }
      }
      await batch.commit(noResult: true);
    });
  }

  // ---- synthetic "Best of" albums ----

  Future<void> saveBestOf(String artist, List<String> paths) => _db.transaction((t) async {
    await t.delete('best_of', where: 'artist = ?', whereArgs: [artist]);
    for (var i = 0; i < paths.length; i++) {
      await t.insert('best_of', {'artist': artist, 'pos': i, 'path': paths[i]});
    }
  });

  /// The artist's best-of songs, most popular first.
  Future<List<Song>> bestOfSongs(String artist) async {
    final rows = await _db.rawQuery(
      'SELECT s.* FROM best_of b JOIN songs s ON s.path = b.path '
      'WHERE b.artist = ? ORDER BY b.pos',
      [artist],
    );
    return _withTags(rows);
  }

  /// One album entry per artist with a best-of; [artist] limits to one.
  Future<List<AlbumInfo>> bestOfAlbums({String? artist, String filter = ''}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT b.artist AS artist, COUNT(*) AS n, MIN(s.path) AS sample
      FROM best_of b JOIN songs s ON s.path = b.path
      ${artist == null ? '' : 'WHERE LOWER(TRIM(b.artist)) = ?'}
      GROUP BY b.artist ORDER BY b.artist COLLATE NOCASE''',
      [if (artist != null) artist.trim().toLowerCase()],
    );
    final f = filter.trim().toLowerCase();
    return [
      for (final r in rows)
        if (f.isEmpty || bestOfTitle(r['artist'] as String).toLowerCase().contains(f))
          AlbumInfo(
            bestOfTitle(r['artist'] as String),
            r['artist'] as String,
            r['n'] as int,
            (await _db.rawQuery('SELECT path FROM best_of WHERE artist = ? ORDER BY pos LIMIT 1', [
                  r['artist'],
                ])).first['path']
                as String,
            synthetic: true,
          ),
    ];
  }

  /// Songs of one album; a synthetic best-of keeps its popularity order.
  Future<List<Song>> albumSongs(String album, String? artist) async {
    if (artist != null && album == bestOfTitle(artist)) return bestOfSongs(artist);
    return search(SongQuery(album: album, artist: artist ?? '', exactNames: true, limit: 2000, sort: SongSort.title));
  }

  /// Updates only the fields found by the online lookups (keeps rating, tempo, etc.).
  Future<void> updateOnline(
    String path, {
    String? lyrics,
    bool? lyricsChecked,
    bool? explicit,
    String? genre,
    int? year,
    bool? mbChecked,
    bool? yearChecked,
  }) {
    final v = <String, Object?>{
      'lyrics': ?lyrics,
      if (lyricsChecked != null) 'lyrics_checked': lyricsChecked ? 1 : 0,
      if (explicit != null) 'explicit': explicit ? 1 : 0,
      'genre': ?genre,
      if (genre != null) 'genre_src': null,
      'year': ?year,
      if (mbChecked != null) 'mb_checked': mbChecked ? 1 : 0,
      if (yearChecked != null) 'year_checked': yearChecked ? 1 : 0,
    };
    if (v.isEmpty) return Future.value();
    return _db.update('songs', v, where: 'path = ?', whereArgs: [path]);
  }

  Future<void> setRating(String path, int rating) =>
      _db.update('songs', {'rating': rating.clamp(0, 5)}, where: 'path = ?', whereArgs: [path]);

  Future<Map<String, int>> knownSongSizes() async => {
    for (final r in await _db.query('songs', columns: ['path', 'size'])) r['path'] as String: (r['size'] as int?) ?? 0,
  };

  /// Size and mtime (ms) of every song, keyed by path.
  Future<Map<String, (int, int)>> knownSongStamps() async => {
    for (final r in await _db.query('songs', columns: ['path', 'size', 'mtime']))
      r['path'] as String: ((r['size'] as int?) ?? 0, (r['mtime'] as int?) ?? 0),
  };

  Future<List<TempoSeg>> segmentsOf(String path) async => [
    for (final r in await _db.query('segments', where: 'path = ?', whereArgs: [path], orderBy: 'start'))
      TempoSeg((r['start'] as num).toDouble(), (r['end'] as num).toDouble(), (r['bpm'] as num).toDouble()),
  ];

  Future<int> songCount() async => (await _db.rawQuery('SELECT COUNT(*) AS n FROM songs')).first['n'] as int;

  /// Duplicate groups with the suggested copy to keep: the one whose folder
  /// holds the most songs (then the longer / larger file).
  Future<List<DupGroup>> duplicateSuggestions() async {
    final dirCounts = <String, int>{};
    for (final r in await _db.rawQuery('SELECT path FROM songs')) {
      final d = dirOf(r['path'] as String);
      dirCounts[d] = (dirCounts[d] ?? 0) + 1;
    }
    return [for (final g in await duplicates()) DupGroup.rank(g, dirCounts)];
  }

  /// Groups of songs sharing the same normalised artist and title.
  Future<List<List<Song>>> duplicates() async {
    final keys = await _db.rawQuery(
      "SELECT dup_key FROM songs WHERE dup_key IS NOT NULL AND dup_key <> '' "
      'GROUP BY dup_key HAVING COUNT(*) > 1 ORDER BY dup_key',
    );
    final out = <List<Song>>[];
    for (final k in keys) {
      final rows = await _db.query('songs', where: 'dup_key = ?', whereArgs: [k['dup_key']], orderBy: 'path');
      out.add([for (final r in rows) Song.fromRow(r)]);
    }
    return out;
  }

  Future<List<Song>> search(SongQuery q) async {
    final (where, args) = _where(q);
    final order = switch (q.sort) {
      SongSort.artist => 'artist COLLATE NOCASE, title COLLATE NOCASE',
      SongSort.title => 'title COLLATE NOCASE',
      SongSort.bpm => 'median_bpm',
      SongSort.steadiness => 'bpm_stddev',
      SongSort.rating => 'rating DESC, artist COLLATE NOCASE',
      SongSort.duration => _playSql,
      SongSort.added => 'added_at DESC, artist COLLATE NOCASE',
      SongSort.random => 'RANDOM()',
    };
    final rows = await _db.query('songs', where: where, whereArgs: args, orderBy: order, limit: q.limit);
    return _withTags(rows);
  }

  /// How many songs match [q] (ignoring its limit).
  Future<int> count(SongQuery q) async {
    final (where, args) = _where(q);
    final r = await _db.rawQuery('SELECT COUNT(*) AS n FROM songs${where == null ? '' : ' WHERE $where'}', args);
    return r.first['n'] as int;
  }

  /// Average length in seconds of the songs matching [q] that have one
  /// (ignoring its limit); null when none do.
  Future<double?> averageDuration(SongQuery q) async {
    final (where, args) = _where(q);
    final r = await _db.rawQuery(
      'SELECT AVG(duration) AS a FROM songs WHERE duration > 0'
      '${where == null ? '' : ' AND $where'}',
      args,
    );
    return (r.first['a'] as num?)?.toDouble();
  }

  /// The median BPM of every song that has one.
  Future<List<double>> medianBpms() async => [
    for (final r in await _db.rawQuery('SELECT median_bpm FROM songs WHERE median_bpm > 0'))
      (r['median_bpm'] as num).toDouble(),
  ];

  (String?, List<Object?>) _where(SongQuery q) {
    final where = <String>[];
    final args = <Object?>[];
    const esc = " ESCAPE '\\'";
    void name(String col, String v) {
      if (v.trim().isEmpty) return;
      if (q.exactNames) {
        where.add('LOWER(TRIM(COALESCE($col, \'\'))) = ?');
        args.add(v.trim().toLowerCase());
      } else {
        where.add('$col LIKE ?$esc');
        args.add(_like(v.trim()));
      }
    }

    name('artist', q.artist);
    name('album', q.album);
    if (q.favOnly) where.add('fav = 1');
    if (q.addedSince != null) {
      where.add('added_at >= ?');
      args.add(q.addedSince);
    }
    if (q.text.trim().isNotEmpty) {
      where.add('(title LIKE ?$esc OR artist LIKE ?$esc OR album LIKE ?$esc OR path LIKE ?$esc)');
      final l = _like(q.text.trim());
      args.addAll([l, l, l, l]);
    }
    if (q.lyrics.trim().isNotEmpty) {
      where.add('lyrics LIKE ?$esc');
      args.add(_like(q.lyrics.trim()));
    }
    final any = [
      for (final t in q.lyricsAny)
        if (t.trim().isNotEmpty) t.trim(),
    ];
    if (any.isNotEmpty) {
      final parts = <String>[];
      for (final t in any) {
        parts.add('lyrics LIKE ?$esc');
        args.add(_like(t));
        if (q.anyIncludesTitle) {
          parts.add('title LIKE ?$esc');
          args.add(_like(t));
        }
      }
      where.add('(${parts.join(' OR ')})');
    }
    for (final t in q.lyricsAll) {
      if (t.trim().isEmpty) continue;
      where.add('lyrics LIKE ?$esc');
      args.add(_like(t.trim()));
    }
    for (final t in q.lyricsNot) {
      if (t.trim().isEmpty) continue;
      where.add('(lyrics IS NULL OR lyrics NOT LIKE ?$esc)');
      args.add(_like(t.trim()));
    }
    if (q.lyricsOnly) where.add("lyrics IS NOT NULL AND lyrics <> ''");
    // a song matches a BPM range when its median tempo falls in it
    if (q.minBpm != null) {
      where.add('median_bpm >= ?');
      args.add(q.minBpm);
    }
    if (q.maxBpm != null) {
      where.add('median_bpm <= ?');
      args.add(q.maxBpm);
    }
    final rpm = q.targetRpm;
    if (rpm != null) {
      final lo = rpm - q.rpmTolerance, hi = rpm + q.rpmTolerance;
      final ranges = [(lo, hi), if (q.halfDouble) (lo / 2, hi / 2), if (q.halfDouble) (lo * 2, hi * 2)];
      where.add('(${[for (final _ in ranges) '(median_bpm BETWEEN ? AND ?)'].join(' OR ')})');
      for (final r in ranges) {
        args.addAll([r.$1, r.$2]);
      }
    }
    if (q.maxStddev != null) {
      where.add('bpm_stddev <= ?');
      args.add(q.maxStddev);
    }
    if (q.minSeconds != null) {
      where.add('$_playSql >= ?');
      args.add(q.minSeconds);
    }
    if (q.maxSeconds != null) {
      where.add('$_playSql <= ?');
      args.add(q.maxSeconds);
    }
    if (q.genre.trim().isNotEmpty) {
      where.add('genre LIKE ?$esc');
      args.add(_like(q.genre.trim()));
    }
    if (q.decade != null) {
      where.add('year >= ? AND year < ?');
      args.addAll([q.decade, q.decade! + 10]);
    }
    if (q.minYear != null) {
      where.add('year >= ?');
      args.add(q.minYear);
    }
    if (q.maxYear != null) {
      where.add('year <= ?');
      args.add(q.maxYear);
    }
    if (q.tag.trim().isNotEmpty) {
      where.add('path IN (SELECT path FROM song_tags WHERE tag = ?)');
      args.add(q.tag.trim().toLowerCase());
    }
    if (q.hideExplicit) where.add('COALESCE(explicit_manual, explicit) = 0');
    if (q.hideUsed) where.add('path NOT IN (SELECT path FROM mix_items)');
    if (q.hideInLastMixes > 0) {
      where.add(
        'path NOT IN (SELECT path FROM mix_items WHERE mix_id IN '
        '(SELECT id FROM mixes WHERE archived = 0 AND id <> ? ORDER BY saved_at DESC LIMIT ?))',
      );
      args.addAll([q.exceptMix ?? -1, q.hideInLastMixes]);
    }
    if (q.hideCorrupt) {
      where.add("path NOT IN (SELECT path FROM song_tags WHERE tag = '$corruptTag')");
    }
    if (q.hideTaughtWithinDays != null) {
      where.add(
        'NOT EXISTS (SELECT 1 FROM class_session_items ci '
        'JOIN class_sessions cs ON cs.id = ci.session_id '
        'WHERE ci.path = songs.path AND cs.taught_at >= ?)',
      );
      args.add(DateTime.now().subtract(Duration(days: q.hideTaughtWithinDays!)).millisecondsSinceEpoch);
    }
    if (q.minRating > 0) {
      where.add('rating >= ?');
      args.add(q.minRating);
    }
    if (q.exclude.isNotEmpty) {
      where.add('path NOT IN (${List.filled(q.exclude.length, '?').join(',')})');
      args.addAll(q.exclude);
    }
    return (where.isEmpty ? null : where.join(' AND '), args);
  }

  // ---- artists and albums ----

  static const _decodeFailed =
      "EXISTS (SELECT 1 FROM song_health h "
      "WHERE h.path = songs.path AND h.reason LIKE 'could not decode%')";
  static const _hasLyrics = "COALESCE(lyrics, '') <> ''";
  static const _hasGenre = "TRIM(COALESCE(genre, '')) <> ''";

  /// Per-group counts behind [Coverage.fromRow], for any `GROUP BY` over songs.
  static const coverageCols =
      '''
      SUM(CASE WHEN median_bpm IS NOT NULL THEN 1 ELSE 0 END) AS cov_bpm,
      SUM(CASE WHEN median_bpm IS NULL AND $_decodeFailed THEN 1 ELSE 0 END) AS cov_bpm_chk,
      SUM(CASE WHEN $_hasLyrics THEN 1 ELSE 0 END) AS cov_lyr,
      SUM(CASE WHEN NOT ($_hasLyrics) AND lyrics_checked = 1 THEN 1 ELSE 0 END) AS cov_lyr_chk,
      SUM(CASE WHEN year IS NOT NULL THEN 1 ELSE 0 END) AS cov_yr,
      SUM(CASE WHEN year IS NULL AND year_checked = 1 THEN 1 ELSE 0 END) AS cov_yr_chk,
      SUM(CASE WHEN $_hasGenre THEN 1 ELSE 0 END) AS cov_gen,
      SUM(CASE WHEN NOT ($_hasGenre) AND mb_checked = 1 THEN 1 ELSE 0 END) AS cov_gen_chk''';

  /// WHERE clause for one artist, album (needs [artist]) or genre.
  /// [noGenre] selects the songs without any genre.
  (String, List<Object?>) _groupWhere({String? artist, String? album, String? genre, bool noGenre = false}) {
    final where = <String>[];
    final args = <Object?>[];
    if (artist != null) {
      where.add("LOWER(TRIM(COALESCE(artist, ''))) = ?");
      args.add(artist.trim().toLowerCase());
    }
    if (album != null) {
      where.add("LOWER(TRIM(COALESCE(album, ''))) = ?");
      args.add(album.trim().toLowerCase());
    }
    if (genre != null) {
      where.add('LOWER(TRIM(genre)) = ?');
      args.add(genre.trim().toLowerCase());
    }
    if (noGenre) where.add('NOT ($_hasGenre)');
    return (where.isEmpty ? '1' : where.join(' AND '), args);
  }

  /// Totals for one artist, album or genre (or the songs with no genre).
  Future<Coverage> coverageOf({String? artist, String? album, String? genre, bool noGenre = false}) async {
    final (where, args) = _groupWhere(artist: artist, album: album, genre: genre, noGenre: noGenre);
    final rows = await _db.rawQuery('SELECT COUNT(*) AS songs, $coverageCols FROM songs WHERE $where', args);
    return Coverage.fromRow(rows.first);
  }

  /// Paths of that group's songs a scan with these options would still work
  /// on: no tempo (and not undecodable), lyrics or genre not looked up yet,
  /// or a year not looked up yet.
  Future<List<String>> incompletePaths({
    String? artist,
    String? album,
    String? genre,
    bool noGenre = false,
    bool fetchLyrics = true,
    bool lookupMusicBrainz = true,
    bool lookupYear = false,
  }) async {
    final (where, args) = _groupWhere(artist: artist, album: album, genre: genre, noGenre: noGenre);
    const named = "TRIM(COALESCE(artist, '')) <> '' AND TRIM(COALESCE(title, '')) <> ''";
    final need = <String>[
      'median_bpm IS NULL AND NOT $_decodeFailed',
      if (fetchLyrics) 'NOT ($_hasLyrics) AND lyrics_checked = 0',
      if (lookupMusicBrainz) '($named AND NOT ($_hasGenre) AND mb_checked = 0)',
      if (lookupMusicBrainz && lookupYear) '($named AND year IS NULL AND year_checked = 0)',
    ];
    final rows = await _db.rawQuery(
      'SELECT path FROM songs WHERE $where AND (${need.join(' OR ')}) ORDER BY path',
      args,
    );
    return [for (final r in rows) r['path'] as String];
  }

  /// One row per artist (names compared ignoring case and spacing).
  /// [bySongs] orders most songs first; [hideUpTo] hides artists with that many
  /// songs or fewer.
  Future<List<ArtistInfo>> artists({String filter = '', bool bySongs = true, int hideUpTo = 0, String? genre}) async {
    final args = <Object?>[];
    var where = "artist IS NOT NULL AND TRIM(artist) <> ''";
    if (filter.trim().isNotEmpty) {
      where += " AND artist LIKE ? ESCAPE '\\'";
      args.add(_like(filter.trim()));
    }
    if (genre != null) {
      where += ' AND LOWER(TRIM(genre)) = ?';
      args.add(genre.trim().toLowerCase());
    }
    final rows = await _db.rawQuery('''
      SELECT MIN(artist) AS name, COUNT(*) AS songs,
             COUNT(DISTINCT LOWER(TRIM(COALESCE(album, '')))) AS albums,
             MIN(path) AS sample, MIN(median_bpm) AS lo, MAX(median_bpm) AS hi,
             SUM(CASE WHEN path IN (SELECT path FROM mix_items) THEN 1 ELSE 0 END) AS used,
             $coverageCols
      FROM songs WHERE $where
      GROUP BY LOWER(TRIM(artist)) HAVING COUNT(*) > $hideUpTo
      ORDER BY ${bySongs ? 'songs DESC, ' : ''}name COLLATE NOCASE''', args);
    return [
      for (final r in rows)
        ArtistInfo(
          r['name'] as String,
          r['songs'] as int,
          r['albums'] as int,
          r['sample'] as String,
          minBpm: (r['lo'] as num?)?.toDouble(),
          maxBpm: (r['hi'] as num?)?.toDouble(),
          used: (r['used'] as int?) ?? 0,
          coverage: Coverage.fromRow(r),
        ),
    ];
  }

  /// One row per album (and artist); pass [artist] for one artist's albums.
  Future<List<AlbumInfo>> albums({
    String filter = '',
    String? artist,
    bool bySongs = false,
    int hideUpTo = 0,
    String? genre,
  }) async {
    final args = <Object?>[];
    var where = "album IS NOT NULL AND TRIM(album) <> ''";
    if (filter.trim().isNotEmpty) {
      where += " AND album LIKE ? ESCAPE '\\'";
      args.add(_like(filter.trim()));
    }
    if (genre != null) {
      where += ' AND LOWER(TRIM(genre)) = ?';
      args.add(genre.trim().toLowerCase());
    }
    if (artist != null) {
      where += " AND LOWER(TRIM(COALESCE(artist, ''))) = ?";
      args.add(artist.trim().toLowerCase());
    }
    final rows = await _db.rawQuery('''
      SELECT MIN(album) AS album, MIN(artist) AS artist, COUNT(*) AS songs,
             MIN(path) AS sample, MIN(year) AS year,
             SUM(CASE WHEN fav = 1 THEN 1 ELSE 0 END) AS favs,
             CASE WHEN COUNT(CASE WHEN duration > 0 THEN 1 END) = COUNT(*)
                  THEN SUM(duration) END AS total_secs,
             MIN(median_bpm) AS lo, MAX(median_bpm) AS hi, $coverageCols
      FROM songs WHERE $where
      GROUP BY LOWER(TRIM(album)), LOWER(TRIM(COALESCE(artist, '')))
      HAVING COUNT(*) > $hideUpTo
      ORDER BY ${bySongs ? 'songs DESC, ' : ''}album COLLATE NOCASE''', args);
    return [
      for (final r in rows)
        AlbumInfo(
          r['album'] as String,
          r['artist'] as String?,
          r['songs'] as int,
          r['sample'] as String,
          year: r['year'] as int?,
          favs: r['favs'] as int,
          totalSecs: (r['total_secs'] as num?)?.toDouble(),
          minBpm: (r['lo'] as num?)?.toDouble(),
          maxBpm: (r['hi'] as num?)?.toDouble(),
          coverage: Coverage.fromRow(r),
        ),
    ];
  }

  /// One row per genre (ignoring case), most songs first.
  Future<List<GenreInfo>> genreSummaries({String filter = ''}) async {
    final args = <Object?>[];
    var where = "genre IS NOT NULL AND TRIM(genre) <> ''";
    if (filter.trim().isNotEmpty) {
      where += " AND genre LIKE ? ESCAPE '\\'";
      args.add(_like(filter.trim()));
    }
    final rows = await _db.rawQuery('''
      SELECT MIN(TRIM(genre)) AS name, COUNT(*) AS songs,
             COUNT(DISTINCT LOWER(TRIM(COALESCE(artist, '')))) AS artists,
             COUNT(DISTINCT CASE WHEN album IS NOT NULL AND TRIM(album) <> ''
               THEN LOWER(TRIM(album)) || '|' || LOWER(TRIM(COALESCE(artist, ''))) END) AS albums,
                            $coverageCols
      FROM songs WHERE $where
      GROUP BY LOWER(TRIM(genre))
      ORDER BY songs DESC, name COLLATE NOCASE''', args);
    final samples = <String, List<String>>{};
    for (final r in await _db.rawQuery('''
      SELECT LOWER(TRIM(genre)) AS g, MIN(path) AS p FROM songs WHERE $where
      GROUP BY g, LOWER(TRIM(COALESCE(album, ''))), LOWER(TRIM(COALESCE(artist, '')))
      ORDER BY MAX(album IS NOT NULL AND TRIM(album) <> '') DESC, g''', args)) {
      final l = samples.putIfAbsent(r['g'] as String, () => []);
      if (l.length < 4) l.add(r['p'] as String);
    }
    return [
      for (final r in rows)
        GenreInfo(
          r['name'] as String,
          r['songs'] as int,
          r['artists'] as int,
          r['albums'] as int,
          samples[(r['name'] as String).toLowerCase()] ?? const [],
          Coverage.fromRow(r),
        ),
    ];
  }

  /// Albums where only [max] songs or fewer are in the library.
  Future<List<AlbumInfo>> discographyGaps({int max = 2}) async => [
    for (final a in await albums())
      if (a.songs <= max) a,
  ];

  /// Lyrics of every song by [artist], for theme analysis.
  Future<List<String>> lyricsOfArtist(String artist) async => [
    for (final r in await _db.query(
      'songs',
      columns: ['lyrics'],
      where: "LOWER(TRIM(COALESCE(artist, ''))) = ? AND lyrics IS NOT NULL AND lyrics <> ''",
      whereArgs: [artist.trim().toLowerCase()],
    ))
      r['lyrics'] as String,
  ];

  /// Songs close to [s] in tempo, genre, decade or artist, best match first.
  Future<List<Song>> similar(Song s, {int limit = 40}) async {
    final or = <String>[];
    final args = <Object?>[s.path];
    final bpm = s.medianBpm;
    if (bpm != null) {
      or.add('(median_bpm BETWEEN ? AND ?)');
      args.addAll([bpm - 8, bpm + 8]);
      or.add('(median_bpm BETWEEN ? AND ?)');
      args.addAll([bpm * 2 - 8, bpm * 2 + 8]);
      or.add('(median_bpm BETWEEN ? AND ?)');
      args.addAll([bpm / 2 - 8, bpm / 2 + 8]);
    }
    if (s.artist != null) {
      or.add("LOWER(TRIM(COALESCE(artist, ''))) = ?");
      args.add(s.artist!.trim().toLowerCase());
    }
    if (s.genre != null) {
      or.add('LOWER(genre) = ?');
      args.add(s.genre!.toLowerCase());
    }
    if (s.year != null) {
      or.add('(year >= ? AND year < ?)');
      final d = s.year! ~/ 10 * 10;
      args.addAll([d, d + 10]);
    }
    if (or.isEmpty) return [];
    final rows = await _db.query('songs', where: 'path <> ? AND (${or.join(' OR ')})', whereArgs: args, limit: 2000);
    final scored = [
      for (final r in rows) Song.fromRow(r),
    ].map((c) => (c, similarity(s, c))).where((e) => e.$2 > 0).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final out = scored.take(limit).map((e) => e.$1).toList();
    final tags = await tagsFor([for (final o in out) o.path]);
    return [for (final o in out) Song.fromRow(o.toRow(), tags[o.path]!)];
  }

  Future<LibraryStats> stats() async {
    Future<int> n(String where) async =>
        (await _db.rawQuery('SELECT COUNT(*) AS n FROM songs WHERE $where')).first['n'] as int;
    final buckets = <int, int>{};
    for (final r in await _db.rawQuery(
      'SELECT CAST(median_bpm / 10 AS INTEGER) * 10 AS b, COUNT(*) AS c '
      'FROM songs WHERE median_bpm IS NOT NULL GROUP BY b ORDER BY b',
    )) {
      buckets[r['b'] as int] = r['c'] as int;
    }
    final decades = <int, int>{};
    for (final r in await _db.rawQuery(
      'SELECT year / 10 * 10 AS d, COUNT(*) AS c FROM songs '
      'WHERE year IS NOT NULL GROUP BY d ORDER BY d',
    )) {
      decades[r['d'] as int] = r['c'] as int;
    }
    final genres = [
      for (final r in await _db.rawQuery(
        "SELECT genre, COUNT(*) AS c FROM songs WHERE genre IS NOT NULL AND genre <> '' "
        'GROUP BY LOWER(genre) ORDER BY c DESC LIMIT 15',
      ))
        MapEntry(r['genre'] as String, r['c'] as int),
    ];
    return LibraryStats(
      total: await songCount(),
      withBpm: await n('median_bpm IS NOT NULL'),
      withLyrics: await n("lyrics IS NOT NULL AND lyrics <> ''"),
      withGenre: await n("genre IS NOT NULL AND genre <> ''"),
      favourites: await n('fav = 1'),
      bpmBuckets: buckets,
      decades: decades,
      genres: genres,
    );
  }

  // ---- favourites and overrides ----

  Future<void> setFav(String path, bool fav) =>
      _db.update('songs', {'fav': fav ? 1 : 0}, where: 'path = ?', whereArgs: [path]);

  Future<Map<String, Object?>?> override(String path) async {
    final r = await _db.query('overrides', where: 'path = ?', whereArgs: [path]);
    return r.isEmpty ? null : r.first;
  }

  /// Sets artist/album/genre/year on many songs. The values are remembered
  /// so a rescan does not put the original tags back; null leaves a field alone.
  Future<void> setOverrides(Iterable<String> paths, {String? artist, String? album, String? genre, int? year}) async {
    await _db.transaction((t) async {
      for (final p in paths) {
        final old = await t.query('overrides', where: 'path = ?', whereArgs: [p]);
        final o = <String, Object?>{
          if (old.isNotEmpty) ...old.first,
          'path': p,
          'artist': ?artist,
          'album': ?album,
          'genre': ?genre,
          'year': ?year,
        };
        await t.insert('overrides', o, conflictAlgorithm: ConflictAlgorithm.replace);
        final upd = <String, Object?>{
          'artist': ?artist,
          'album': ?album,
          'genre': ?genre,
          if (genre != null) 'genre_src': null,
          'year': ?year,
        };
        if (artist != null) {
          final r = await t.query('songs', columns: ['title'], where: 'path = ?', whereArgs: [p]);
          if (r.isNotEmpty) upd['dup_key'] = dupKeyFor(artist, r.first['title'] as String?);
        }
        if (upd.isNotEmpty) await t.update('songs', upd, where: 'path = ?', whereArgs: [p]);
      }
    });
  }

  /// The manual BPM fix stored in an [override] row, if any.
  static ManualBpm? bpmFixOf(Map<String, Object?>? ov) {
    final bpm = (ov?['bpm'] as num?)?.toDouble();
    final scale = (ov?['bpm_scale'] as num?)?.toDouble();
    if (bpm != null) return ManualBpm(bpm: bpm);
    if (scale != null) return ManualBpm(scale: scale);
    return null;
  }

  Future<ManualBpm?> bpmFix(String path) async => bpmFixOf(await override(path));

  /// Corrects a wrongly detected tempo: [scale] multiplies it (0.5 / 2), [bpm]
  /// replaces it with one constant tempo; both null clears the fix. Remembered
  /// in overrides (so rescans keep it), applied to the song's BPM stats and
  /// segments, and written into the `.bpm` sidecar for the phone app.
  Future<void> setBpmFix(String path, {double? scale, double? bpm}) async {
    assert(scale == null || bpm == null, 'set either scale or bpm, not both');
    final fix = bpm != null
        ? ManualBpm(bpm: bpm)
        : scale != null
        ? ManualBpm(scale: scale)
        : null;
    final oldOv = await override(path);
    final oldFix = bpmFixOf(oldOv);
    await _db.insert('overrides', {
      ...?oldOv,
      'path': path,
      'bpm_scale': fix?.scale,
      'bpm': fix?.bpm,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final stored = await BpmStore.load(path);
    var raw = stored?.rawMapFor(baselineId);
    if (stored != null) {
      try {
        await BpmStore.save(path, stored.withManual(fix));
      } catch (_) {
        // read-only folder: the DB still has the fix
      }
    }
    if (raw == null) {
      // No sidecar: undo the previous fix on the stored segments. A previous
      // constant-bpm fix can't be undone; the next analysis restores it.
      final song = await this.song(path);
      final segs = await segmentsOf(path);
      if (song == null || (segs.isEmpty && fix?.bpm == null)) return;
      final dur = song.duration ?? (segs.isEmpty ? 0.0 : segs.last.end);
      final div = oldFix?.scale ?? 1;
      raw = TempoMap(durationSec: dur, segments: [for (final s in segs) TempoSegment(s.start, s.end, s.bpm / div)]);
    }
    final stats = TempoStats.of(fix?.apply(raw) ?? raw);
    await _db.transaction((t) async {
      await t.update('songs', stats.toRow(), where: 'path = ?', whereArgs: [path]);
      await t.delete('segments', where: 'path = ?', whereArgs: [path]);
      for (final g in stats.segments) {
        await t.insert('segments', {'path': path, 'start': g.start, 'end': g.end, 'bpm': g.bpm});
      }
    });
  }

  // ---- mix history ----

  /// Saved mixes that contain [path], newest first.
  Future<List<MixInfo>> mixesUsing(String path) async => [
    for (final r in await _db.rawQuery(
      'SELECT m.id, m.name, m.saved_at FROM mixes m '
      'WHERE m.id IN (SELECT mix_id FROM mix_items WHERE path = ?) '
      'ORDER BY m.saved_at DESC, m.name COLLATE NOCASE',
      [path],
    ))
      MixInfo(r['id'] as int, r['name'] as String, savedAt: r['saved_at'] as int?),
  ];

  // ---- smart playlists ----

  Future<List<SmartList>> smartLists() async {
    final out = <SmartList>[];
    for (final r in await _db.query('smart_lists', orderBy: 'name COLLATE NOCASE')) {
      try {
        out.add(
          SmartList(
            r['id'] as int,
            r['name'] as String,
            SongQuery.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>),
          ),
        );
      } catch (_) {}
    }
    return out;
  }

  Future<void> saveSmartList(String name, SongQuery q) => _db.insert('smart_lists', {
    'name': name.trim(),
    'json': jsonEncode(q.toJson()),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteSmartList(int id) => _db.delete('smart_lists', where: 'id = ?', whereArgs: [id]);

  // ---- genre lists (artist level, overridden by album, then song) ----

  static String _gk(String? s) => (s ?? '').trim().toLowerCase();

  /// Sets the artist's default genre (empty removes it) and re-applies the lists.
  Future<void> setArtistGenre(String artist, String genre) async {
    final g = genre.trim();
    if (g.isEmpty) {
      await _db.delete('artist_genres', where: 'key = ?', whereArgs: [_gk(artist)]);
    } else {
      await _db.insert('artist_genres', {
        'key': _gk(artist),
        'name': artist.trim(),
        'genre': g,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await applyGenreLists();
  }

  /// Sets an album genre. [source] is 'user' or 'api'; an API value never
  /// replaces one the user typed.
  Future<void> setAlbumGenre(
    String artist,
    String album,
    String genre, {
    String source = 'user',
    bool apply = true,
  }) async {
    final key = '${_gk(artist)}|${_gk(album)}';
    final g = genre.trim();
    if (g.isEmpty) {
      await _db.delete('album_genres', where: 'key = ?', whereArgs: [key]);
    } else {
      final old = await _db.query('album_genres', where: 'key = ?', whereArgs: [key]);
      if (old.isNotEmpty && source == 'api') return;
      await _db.insert('album_genres', {
        'key': key,
        'artist': artist.trim(),
        'album': album.trim(),
        'genre': g,
        'source': source,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (apply) await applyGenreLists();
  }

  Future<String?> artistGenre(String artist) async {
    final r = await _db.query('artist_genres', where: 'key = ?', whereArgs: [_gk(artist)]);
    return r.isEmpty ? null : r.first['genre'] as String?;
  }

  /// Fills the genre of songs that have none of their own: album list first,
  /// then artist list. Genres from tags, the API or manual edits are never touched.
  Future<void> applyGenreLists() async {
    const k = "LOWER(TRIM(IFNULL(artist,'')))";
    await _db.transaction((t) async {
      await t.execute("UPDATE songs SET genre = NULL, genre_src = NULL WHERE genre_src IS NOT NULL");
      await t.execute('''UPDATE songs SET genre_src = 'album',
          genre = (SELECT genre FROM album_genres a
                   WHERE a.key = $k || '|' || LOWER(TRIM(IFNULL(songs.album,''))))
        WHERE (genre IS NULL OR genre = '') AND EXISTS (SELECT 1 FROM album_genres a
                   WHERE a.key = $k || '|' || LOWER(TRIM(IFNULL(songs.album,''))))''');
      await t.execute('''UPDATE songs SET genre_src = 'artist',
          genre = (SELECT genre FROM artist_genres a WHERE a.key = $k)
        WHERE (genre IS NULL OR genre = '') AND EXISTS (SELECT 1 FROM artist_genres a WHERE a.key = $k)''');
    });
  }

  /// JSON for the genre file: {"artists": {name: genre}, "albums": [{artist, album, genre}]}.
  Future<String> exportGenreFile() async => const JsonEncoder.withIndent('  ').convert({
    'artists': {
      for (final r in await _db.query('artist_genres', orderBy: 'key')) r['name'] as String: r['genre'] as String,
    },
    'albums': [
      for (final r in await _db.query('album_genres', orderBy: 'key'))
        {'artist': r['artist'], 'album': r['album'], 'genre': r['genre']},
    ],
  });

  /// Merges a genre file into the lists; returns how many entries were read.
  Future<int> importGenreFile(String json) async {
    final j = jsonDecode(json) as Map<String, dynamic>;
    var n = 0;
    for (final e in (j['artists'] as Map<String, dynamic>? ?? {}).entries) {
      final g = '${e.value}'.trim();
      if (g.isEmpty) continue;
      await _db.insert('artist_genres', {
        'key': _gk(e.key),
        'name': e.key.trim(),
        'genre': g,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      n++;
    }
    for (final a in (j['albums'] as List? ?? [])) {
      final m = a as Map<String, dynamic>;
      final g = '${m['genre'] ?? ''}'.trim();
      if (g.isEmpty) continue;
      await _db.insert('album_genres', {
        'key': '${_gk(m['artist'] as String?)}|${_gk(m['album'] as String?)}',
        'artist': m['artist'],
        'album': m['album'],
        'genre': g,
        'source': 'user',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      n++;
    }
    await applyGenreLists();
    return n;
  }

  /// Replaces ID3 genre codes such as "(108)" saved from tags with their
  /// names (or clears them). Returns how many rows changed.
  Future<int> cleanGenreCodes() async {
    var n = 0;
    for (final table in ['songs', 'overrides', 'artist_genres', 'album_genres']) {
      final rows = await _db.rawQuery("SELECT DISTINCT genre FROM $table WHERE genre GLOB '[(0-9]*'");
      for (final r in rows) {
        final raw = r['genre'] as String;
        final clean = cleanGenre(raw);
        if (clean == raw) continue;
        n += await _db.update(table, {'genre': clean.isEmpty ? null : clean}, where: 'genre = ?', whereArgs: [raw]);
      }
    }
    return n;
  }

  /// Folds near-duplicate genre spellings into one name and turns junk
  /// into "Unknown" everywhere genres are stored (see [canonicalGenre]).
  /// Returns how many rows changed.
  Future<int> mergeGenres() async {
    var n = 0;
    for (final table in ['songs', 'overrides', 'artist_genres', 'album_genres']) {
      final rows = await _db.rawQuery("SELECT DISTINCT genre FROM $table WHERE genre IS NOT NULL AND genre <> ''");
      for (final r in rows) {
        final raw = r['genre'] as String;
        final canon = cleanGenre(raw);
        if (canon == raw) continue;
        n += await _db.update(table, {'genre': canon.isEmpty ? null : canon}, where: 'genre = ?', whereArgs: [raw]);
      }
    }
    return n;
  }

  Future<List<String>> genres() async => [
    for (final r in await _db.rawQuery(
      "SELECT DISTINCT genre FROM songs WHERE genre IS NOT NULL AND genre <> '' ORDER BY genre COLLATE NOCASE",
    ))
      r['genre'] as String,
  ];

  /// The genre of every song as shown (an inherited album/artist genre
  /// counts), keyed by path; songs without one are left out.
  Future<Map<String, String>> songGenres() async => {
    for (final r in await _db.rawQuery("SELECT path, genre FROM songs WHERE genre IS NOT NULL AND genre <> ''"))
      r['path'] as String: r['genre'] as String,
  };

  /// Distinct decades (e.g. 1980) of songs in the library, ascending. Year
  /// overrides are written into songs.year, so this matches what search sees.
  Future<List<int>> decades() async => [
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT year / 10 * 10 AS d FROM songs '
      'WHERE year >= 1900 AND year <= ? ORDER BY d',
      [DateTime.now().year + 1],
    ))
      r['d'] as int,
  ];

  Future<List<String>> artistNames() async => [
    for (final r in await _db.rawQuery(
      "SELECT artist, COUNT(*) AS n FROM songs WHERE artist IS NOT NULL AND artist <> '' GROUP BY artist ORDER BY n DESC, artist COLLATE NOCASE",
    ))
      r['artist'] as String,
  ];

  // ---- user tags ----

  Future<List<String>> tagsOf(String path) async => [
    for (final r in await _db.query('song_tags', where: 'path = ?', whereArgs: [path], orderBy: 'tag'))
      r['tag'] as String,
  ];

  /// Stays under SQLite's bound-variable limit (999 in older builds).
  static const _maxVars = 900;

  static Iterable<List<String>> _chunks(List<String> xs) sync* {
    for (var i = 0; i < xs.length; i += _maxVars) {
      yield xs.sublist(i, i + _maxVars < xs.length ? i + _maxVars : xs.length);
    }
  }

  static String _marks(int n) => List.filled(n, '?').join(',');

  /// [tagsOf] for many songs in a few queries; every path gets an entry.
  Future<Map<String, List<String>>> tagsFor(Iterable<String> paths) async {
    final ps = paths.toSet().toList();
    final out = {for (final p in ps) p: <String>[]};
    for (final c in _chunks(ps)) {
      for (final r in await _db.query(
        'song_tags',
        columns: ['path', 'tag'],
        where: 'path IN (${_marks(c.length)})',
        whereArgs: c,
        orderBy: 'tag',
      )) {
        out[r['path'] as String]?.add(r['tag'] as String);
      }
    }
    return out;
  }

  /// Songs for [rows], with their user tags loaded in bulk.
  Future<List<Song>> _withTags(List<Map<String, Object?>> rows) async {
    final tags = await tagsFor([for (final r in rows) r['path'] as String]);
    return [for (final r in rows) Song.fromRow(r, tags[r['path']]!)];
  }

  Future<List<String>> allTags() async => [
    for (final r in await _db.rawQuery('SELECT DISTINCT tag FROM song_tags ORDER BY tag')) r['tag'] as String,
  ];

  Future<void> addTag(String path, String tag) async {
    tag = tag.trim().toLowerCase();
    await _db.insert('song_tags', {'path': path, 'tag': tag}, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (tag == corruptTag) {
      final prev = (await healthOf([path]))[path];
      if (prev == null || !prev.damaged) {
        await _putHealth(path, 'damaged', 'Marked damaged by you', 'manual', size: prev?.size, mtime: prev?.mtime);
      }
    }
  }

  /// Removing [corruptTag] by hand records an override, so later checks of the
  /// same file don't tag it again.
  Future<void> removeTag(String path, String tag) async {
    await _db.delete('song_tags', where: 'path = ? AND tag = ?', whereArgs: [path, tag]);
    if (tag == corruptTag) {
      await _db.update('song_health', {'status': 'override'}, where: 'path = ?', whereArgs: [path]);
    }
  }

  // ---- damaged audio ----

  static const _depthRank = {'quick': 1, 'deep': 2, 'decode': 2, 'manual': 3};

  Future<void> _putHealth(String path, String status, String? reason, String depth, {int? size, int? mtime}) =>
      _db.insert('song_health', {
        'path': path,
        'size': size,
        'mtime': mtime,
        'status': status,
        'reason': reason,
        'depth': depth,
        'checked_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Stores a damage-check result for [path] ([depth]: quick / deep / decode)
  /// and keeps the [corruptTag] in step. A clean result never clears damage
  /// found by a stricter check (or by hand) on the same file, and damage is
  /// not re-flagged on a file the user overrode. Returns whether the song is
  /// now tagged damaged.
  Future<bool> recordHealth(
    String path, {
    required bool damaged,
    String? reason,
    required String depth,
    required int size,
    required int mtime,
  }) async {
    final prev = (await healthOf([path]))[path];
    final same = prev != null && prev.size == size && prev.mtime == mtime;
    if (damaged) {
      if (same && prev.status == 'override') return false;
      await _putHealth(path, 'damaged', reason, depth, size: size, mtime: mtime);
      await _db.insert('song_tags', {'path': path, 'tag': corruptTag}, conflictAlgorithm: ConflictAlgorithm.ignore);
      return true;
    }
    if (same && prev.damaged && (_depthRank[prev.depth] ?? 0) > (_depthRank[depth] ?? 0)) {
      return true;
    }
    if (same && prev.status == 'override') return false;
    await _putHealth(path, 'ok', null, depth, size: size, mtime: mtime);
    await _db.delete('song_tags', where: 'path = ? AND tag = ?', whereArgs: [path, corruptTag]);
    return false;
  }

  /// Last check of each of [paths] that has one.
  Future<Map<String, SongHealth>> healthOf(Iterable<String> paths) async {
    final out = <String, SongHealth>{};
    for (final c in _chunks(paths.toSet().toList())) {
      for (final r in await _db.query('song_health', where: 'path IN (${_marks(c.length)})', whereArgs: c)) {
        out[r['path'] as String] = _health(r);
      }
    }
    return out;
  }

  SongHealth _health(Map<String, Object?> r) => SongHealth(
    r['path'] as String,
    r['status'] as String,
    reason: r['reason'] as String?,
    depth: r['depth'] as String?,
    checkedAt: r['checked_at'] as int?,
    size: r['size'] as int?,
    mtime: r['mtime'] as int?,
  );

  /// Every song currently tagged damaged, with the reason where known.
  Future<List<(Song, SongHealth?)>> damagedSongs() async {
    final rows = await _db.rawQuery(
      'SELECT s.* FROM songs s '
      "JOIN song_tags t ON t.path = s.path AND t.tag = '$corruptTag' "
      'ORDER BY s.artist COLLATE NOCASE, s.title COLLATE NOCASE',
    );
    final songs = await _withTags(rows);
    final h = await healthOf(songs.map((s) => s.path));
    return [for (final s in songs) (s, h[s.path])];
  }

  /// (size, mtime) each file had when last checked at [depth] or stricter,
  /// so unchanged files can be skipped.
  Future<Map<String, (int?, int?)>> healthChecked({String depth = 'quick'}) async {
    final min = _depthRank[depth] ?? 1;
    return {
      for (final r in await _db.query('song_health'))
        if ((_depthRank[r['depth']] ?? 0) >= min || r['status'] == 'override')
          r['path'] as String: (r['size'] as int?, r['mtime'] as int?),
    };
  }

  /// Number of damaged songs in each saved mix that has any.
  Future<Map<int, int>> damagedCountByMix() async => {
    for (final r in await _db.rawQuery(
      'SELECT m.mix_id AS id, COUNT(*) AS n '
      'FROM mix_items m JOIN song_tags t ON t.path = m.path '
      "WHERE t.tag = '$corruptTag' GROUP BY m.mix_id",
    ))
      r['id'] as int: r['n'] as int,
  };

  // ---- mixes ----

  Future<List<MixInfo>> mixes() async => [
    for (final r in await _db.query('mixes', orderBy: 'name COLLATE NOCASE'))
      MixInfo(
        r['id'] as int,
        r['name'] as String,
        savedAt: r['saved_at'] as int?,
        programJson: r['program'] as String?,
      ),
  ];

  /// Saves [paths] as mix [name], replacing any existing mix of that name.
  /// [program] (JSON) is the program the mix was built from, if any, so a
  /// reloaded mix can match its songs back to the right parts even if a
  /// different program is selected in the meantime. [notes] are per-song
  /// coaching notes by path.
  Future<int> saveMix(
    String name,
    List<String> paths, {
    List<int?>? parts,
    String? program,
    Map<String, String> notes = const {},
  }) => _db.transaction((t) async {
    final ex = await t.query('mixes', where: 'name = ?', whereArgs: [name]);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = ex.isEmpty
        ? await t.insert('mixes', {'name': name, 'saved_at': now, 'program': program})
        : ex.first['id'] as int;
    if (ex.isNotEmpty) {
      await t.update('mixes', {'saved_at': now, 'program': program}, where: 'id = ?', whereArgs: [id]);
    }
    await t.delete('mix_items', where: 'mix_id = ?', whereArgs: [id]);
    for (var i = 0; i < paths.length; i++) {
      await t.insert('mix_items', {
        'mix_id': id,
        'pos': i,
        'path': paths[i],
        'part': parts != null && i < parts.length ? parts[i] : null,
        'note': notes[paths[i]],
      });
    }
    return id;
  });

  /// Per-song notes of mix [id], by path.
  Future<Map<String, String>> mixNotes(int id) async => {
    for (final r in await _db.query(
      'mix_items',
      columns: ['path', 'note'],
      where: "mix_id = ? AND note IS NOT NULL AND note <> ''",
      whereArgs: [id],
    ))
      r['path'] as String: r['note'] as String,
  };

  /// Sets (or with nulls clears) where [path] starts and stops playing.
  Future<void> setTrim(String path, double? start, double? end) =>
      _db.update('songs', {'trim_start': start, 'trim_end': end}, where: 'path = ?', whereArgs: [path]);

  /// The user's explicit (true) / clean (false) mark; null goes back to the lyrics check.
  Future<void> setExplicitMark(Iterable<String> paths, bool? explicit) => _db.transaction((t) async {
    for (final p in paths) {
      await t.update(
        'songs',
        {'explicit_manual': explicit == null ? null : (explicit ? 1 : 0)},
        where: 'path = ?',
        whereArgs: [p],
      );
    }
  });

  Future<void> setLoudness(String path, double lufs) =>
      _db.update('songs', {'loudness': lufs}, where: 'path = ?', whereArgs: [path]);

  /// Paths of songs with no loudness yet (for the Tools backfill).
  Future<List<String>> pathsWithoutLoudness() async => [
    for (final r in await _db.query('songs', columns: ['path'], where: 'loudness IS NULL', orderBy: 'path'))
      r['path'] as String,
  ];

  /// Records that [paths] were used in a mix (saved or sent) at [when].
  Future<void> markMixed(Iterable<String> paths, {DateTime? when}) {
    final at = (when ?? DateTime.now()).millisecondsSinceEpoch;
    return _db.transaction((t) async {
      for (final p in paths) {
        await t.update('songs', {'last_mixed': at}, where: 'path = ?', whereArgs: [p]);
      }
    });
  }

  /// Songs put in a mix (saved or sent) at or after [since].
  Future<Set<String>> pathsMixedSince(DateTime since) async => {
    for (final r in await _db.query(
      'songs',
      columns: ['path'],
      where: 'last_mixed >= ?',
      whereArgs: [since.millisecondsSinceEpoch],
    ))
      r['path'] as String,
  };

  /// Paths used in any of the [n] most recently saved mixes (except [exceptMix]).
  Future<Set<String>> pathsInRecentMixes(int n, {int? exceptMix}) async {
    if (n <= 0) return {};
    final rows = await _db.rawQuery(
      'SELECT DISTINCT i.path FROM mix_items i WHERE i.mix_id IN '
      '(SELECT id FROM mixes WHERE archived = 0 AND id <> ? ORDER BY saved_at DESC LIMIT ?)',
      [exceptMix ?? -1, n],
    );
    return {for (final r in rows) r['path'] as String};
  }

  /// A consistent copy of the whole database at [path] (must not exist).
  Future<void> copyTo(String path) => _db.execute('VACUUM INTO ?', [path]);

  /// Schema version of this database.
  Future<int> schemaVersion() => _db.getVersion();

  /// Part index of each item in mix [id], in order (null where unassigned).
  Future<List<int?>> mixParts(int id) async => [
    for (final r in await _db.query('mix_items', where: 'mix_id = ?', whereArgs: [id], orderBy: 'pos'))
      r['part'] as int?,
  ];

  Future<List<String>> mixPaths(int id) async => [
    for (final r in await _db.query('mix_items', where: 'mix_id = ?', whereArgs: [id], orderBy: 'pos'))
      r['path'] as String,
  ];

  Future<void> deleteMix(int id) => deleteMixes([id]);

  /// Deletes mixes [ids] in one transaction and returns what was removed,
  /// so [restoreMixes] can undo it (same ids, so phone identities survive).
  Future<DeletedMixes> deleteMixes(List<int> ids) => _db.transaction((t) async {
    final out = DeletedMixes._([], [], []);
    for (final id in ids) {
      out._mixes.addAll(await t.query('mixes', where: 'id = ?', whereArgs: [id]));
      out._items.addAll(await t.query('mix_items', where: 'mix_id = ?', whereArgs: [id]));
      out._tags.addAll(await t.query('mix_tags', where: 'mix_id = ?', whereArgs: [id]));
      for (final table in ['mix_items', 'mix_tags']) {
        await t.delete(table, where: 'mix_id = ?', whereArgs: [id]);
      }
      await t.delete('mixes', where: 'id = ?', whereArgs: [id]);
    }
    return out;
  });

  /// Puts back mixes removed by [deleteMixes]. A mix whose name was taken
  /// in the meantime comes back as "NAME (restored)".
  Future<void> restoreMixes(DeletedMixes d) => _db.transaction((t) async {
    for (final m in d._mixes) {
      final row = Map<String, Object?>.of(m);
      var name = row['name'] as String;
      while ((await t.query('mixes', columns: ['id'], where: 'name = ?', whereArgs: [name])).isNotEmpty) {
        name = '$name (restored)';
      }
      row['name'] = name;
      await t.insert('mixes', row);
    }
    for (final r in d._items) {
      await t.insert('mix_items', r);
    }
    for (final r in d._tags) {
      await t.insert('mix_tags', r);
    }
  });

  Future<void> setMixIcon(int id, MixIconSpec? icon) =>
      _db.update('mixes', {'icon': icon?.encode()}, where: 'id = ?', whereArgs: [id]);

  Future<MixIconSpec?> mixIcon(int id) async {
    final r = await _db.query('mixes', columns: ['icon'], where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : MixIconSpec.decode(r.first['icon'] as String?);
  }

  Future<void> setMixesPinned(List<int> ids, bool pinned) => _setFlag(ids, 'pinned', pinned);

  Future<void> setMixesArchived(List<int> ids, bool archived) => _setFlag(ids, 'archived', archived);

  Future<void> _setFlag(List<int> ids, String col, bool on) => _db.transaction((t) async {
    for (final id in ids) {
      await t.update('mixes', {col: on ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    }
  });

  Future<void> noteMixOpened(int id) =>
      _db.update('mixes', {'last_opened': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);

  /// Adds (or with [remove], removes) [tag] on mixes [ids].
  Future<void> tagMixes(List<int> ids, String tag, {bool remove = false}) {
    tag = tag.trim();
    if (tag.isEmpty) return Future.value();
    return _db.transaction((t) async {
      for (final id in ids) {
        if (remove) {
          await t.delete('mix_tags', where: 'mix_id = ? AND tag = ?', whereArgs: [id, tag]);
        } else {
          await t.insert('mix_tags', {'mix_id': id, 'tag': tag}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
  }

  /// Every mix tag in use, sorted.
  Future<List<String>> allMixTags() async => [
    for (final r in await _db.rawQuery('SELECT DISTINCT tag FROM mix_tags ORDER BY tag COLLATE NOCASE'))
      r['tag'] as String,
  ];

  /// Up to four songs per mix with distinct albums (in mix order), for the
  /// album-art collage of mixes without an icon.
  Future<Map<int, List<String>>> mixArtPaths() async {
    final out = <int, List<String>>{};
    final albums = <int, Set<String>>{};
    for (final r in await _db.rawQuery(
      'SELECT i.mix_id AS id, i.path, s.album, s.artist '
      'FROM mix_items i JOIN songs s ON s.path = i.path ORDER BY i.mix_id, i.pos',
    )) {
      final id = r['id'] as int;
      final list = out.putIfAbsent(id, () => []);
      if (list.length >= 4) continue;
      final album = r['album'] as String?;
      final key = album == null || album.isEmpty
          ? r['path'] as String
          : '${(r['artist'] as String?)?.toLowerCase()}|${album.toLowerCase()}';
      if (albums.putIfAbsent(id, () => {}).add(key)) list.add(r['path'] as String);
    }
    return out;
  }

  // ---- mix manager ----

  /// Renames mix [id]. Throws [MixNameTaken] if another mix already has
  /// [name]. The phone identity (`mix_key:<id>`) is keyed by id, so it stays.
  Future<void> renameMix(int id, String name) async {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'must not be empty');
    final clash = await _db.query('mixes', columns: ['id'], where: 'name = ? AND id != ?', whereArgs: [name, id]);
    if (clash.isNotEmpty) throw MixNameTaken(name);
    await _db.update('mixes', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  /// Copies mix [id] (songs, parts and program) as [newName] and returns the
  /// new id. The copy gets no `mix_key`, so it becomes its own phone mixtape.
  /// Throws [MixNameTaken] if [newName] is in use.
  Future<int> duplicateMix(int id, String newName) {
    newName = newName.trim();
    if (newName.isEmpty) throw ArgumentError.value(newName, 'newName', 'must not be empty');
    return _db.transaction((t) async {
      if ((await t.query('mixes', columns: ['id'], where: 'name = ?', whereArgs: [newName])).isNotEmpty) {
        throw MixNameTaken(newName);
      }
      final src = await t.query('mixes', where: 'id = ?', whereArgs: [id]);
      if (src.isEmpty) throw StateError('No mix $id');
      final copy = await t.insert('mixes', {
        'name': newName,
        'saved_at': DateTime.now().millisecondsSinceEpoch,
        'program': src.first['program'],
        'icon': src.first['icon'],
      });
      await t.rawInsert(
        'INSERT INTO mix_items(mix_id, pos, path, part, note) '
        'SELECT ?, pos, path, part, note FROM mix_items WHERE mix_id = ?',
        [copy, id],
      );
      await t.rawInsert('INSERT INTO mix_tags(mix_id, tag) SELECT ?, tag FROM mix_tags WHERE mix_id = ?', [copy, id]);
      return copy;
    });
  }

  /// Every saved mix with its song count, total length and program name, in
  /// one query (songs no longer in the library count but add no length).
  Future<List<MixSummary>> mixSummaries() async => [
    for (final r in await _db.rawQuery(
      'SELECT m.id, m.name, m.saved_at, m.program, m.icon, m.pinned, m.archived, '
      'm.last_opened, COUNT(i.pos) AS n, COALESCE(SUM(COALESCE(s.trim_end, s.duration) - COALESCE(s.trim_start, 0)), 0) AS secs, '
      '(SELECT GROUP_CONCAT(tag, char(31)) FROM '
      '(SELECT tag FROM mix_tags t WHERE t.mix_id = m.id ORDER BY tag COLLATE NOCASE)) AS tags '
      'FROM mixes m LEFT JOIN mix_items i ON i.mix_id = m.id '
      'LEFT JOIN songs s ON s.path = i.path '
      'GROUP BY m.id ORDER BY m.name COLLATE NOCASE',
    ))
      MixSummary(
        r['id'] as int,
        r['name'] as String,
        savedAt: r['saved_at'] as int?,
        programJson: r['program'] as String?,
        songCount: r['n'] as int,
        totalSeconds: (r['secs'] as num).toDouble(),
        icon: MixIconSpec.decode(r['icon'] as String?),
        pinned: r['pinned'] == 1,
        archived: r['archived'] == 1,
        lastOpened: r['last_opened'] as int?,
        tags: (r['tags'] as String?)?.split('\u001f') ?? const [],
      ),
  ];

  // ---- play history ----

  /// A play counts once it ran to the end or was listened to for this long.
  static const countedSeconds = 30;

  Future<void> recordPlay(String path, double listened, bool completed, {String app = 'analyze-this', int? at}) =>
      _db.insert('plays', {
        'path': path,
        'played_at': at ?? DateTime.now().millisecondsSinceEpoch,
        'listened': listened,
        'completed': completed ? 1 : 0,
        'app': app,
      });

  static const _counted = '(completed = 1 OR listened >= $countedSeconds)';

  Future<PlayStat> playStat(String path) async {
    final r = await _db.rawQuery(
      'SELECT SUM($_counted) AS plays, SUM(NOT $_counted) AS skips, '
      'MAX(played_at) AS last FROM plays WHERE path = ?',
      [path],
    );
    final m = r.first;
    return PlayStat(path, (m['plays'] as int?) ?? 0, (m['skips'] as int?) ?? 0, m['last'] as int?);
  }

  Future<List<PlayStat>> mostPlayed({int limit = 50}) async => [
    for (final m in await _db.rawQuery(
      'SELECT path, SUM($_counted) AS plays, SUM(NOT $_counted) AS skips, '
      'MAX(played_at) AS last FROM plays WHERE path IN (SELECT path FROM songs) '
      'GROUP BY path HAVING plays > 0 ORDER BY plays DESC, last DESC LIMIT ?',
      [limit],
    ))
      PlayStat(m['path'] as String, m['plays'] as int, (m['skips'] as int?) ?? 0, m['last'] as int?),
  ];

  Future<List<PlayStat>> mostSkipped({int limit = 50}) async => [
    for (final m in await _db.rawQuery(
      'SELECT path, SUM($_counted) AS plays, SUM(NOT $_counted) AS skips, '
      'MAX(played_at) AS last FROM plays WHERE path IN (SELECT path FROM songs) '
      'GROUP BY path HAVING skips > 0 ORDER BY skips DESC, last DESC LIMIT ?',
      [limit],
    ))
      PlayStat(m['path'] as String, (m['plays'] as int?) ?? 0, m['skips'] as int, m['last'] as int?),
  ];

  Future<List<Song>> recentlyPlayed({int limit = 50}) async {
    final paths = [
      for (final r in await _db.rawQuery(
        'SELECT path FROM plays WHERE path IN (SELECT path FROM songs) '
        'GROUP BY path ORDER BY MAX(played_at) DESC LIMIT ?',
        [limit],
      ))
        r['path'] as String,
    ];
    final rows = <Map<String, Object?>>[];
    for (final c in _chunks(paths)) {
      rows.addAll(await _db.query('songs', where: 'path IN (${_marks(c.length)})', whereArgs: c));
    }
    final byPath = {for (final s in await _withTags(rows)) s.path: s};
    return [for (final p in paths) ?byPath[p]];
  }

  /// Favourites and highly rated songs not played for [days] days (or never).
  Future<List<Song>> forgottenFavorites({int days = 90, int limit = 100}) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - days * 86400000;
    final rows = await _db.rawQuery(
      'SELECT * FROM songs s WHERE (fav = 1 OR rating >= 4) AND NOT EXISTS '
      '(SELECT 1 FROM plays p WHERE p.path = s.path AND p.played_at > ?) '
      'ORDER BY rating DESC, artist COLLATE NOCASE LIMIT ?',
      [cutoff, limit],
    );
    return _withTags(rows);
  }

  /// Merges plays from another source; rows already present are skipped.
  Future<int> importPlays(Iterable<Map<String, Object?>> plays) async {
    var n = 0;
    await _db.transaction((t) async {
      for (final p in plays) {
        final path = p['path'] as String?;
        final at = p['at'] as int?;
        if (path == null || at == null) continue;
        final ex = await t.query(
          'plays',
          columns: ['id'],
          where: 'path = ? AND played_at = ?',
          whereArgs: [path, at],
          limit: 1,
        );
        if (ex.isNotEmpty) continue;
        await t.insert('plays', {
          'path': path,
          'played_at': at,
          'listened': (p['listened'] as num?)?.toDouble() ?? 0,
          'completed': p['done'] == true ? 1 : 0,
          'app': p['app'] ?? 'other',
        });
        n++;
      }
    });
    return n;
  }

  // ---- class history ----

  /// Same rule as the SQL counted-play filter used by the play stats.
  static bool isCountedPlay(double listened, bool completed) => completed || listened >= countedSeconds;

  /// Logs that a class was taught from a mix, snapshotting [paths] (in order).
  Future<int> logClass({
    int? mixId,
    required String mixName,
    required List<String> paths,
    required DateTime taughtAt,
    String source = 'manual',
  }) => _db.transaction((t) async {
    final id = await t.insert('class_sessions', {
      'mix_id': mixId,
      'mix_name': mixName,
      'taught_at': taughtAt.millisecondsSinceEpoch,
      'source': source,
    });
    final b = t.batch();
    for (var i = 0; i < paths.length; i++) {
      b.insert('class_session_items', {'session_id': id, 'pos': i, 'path': paths[i]});
    }
    await b.commit(noResult: true);
    return id;
  });

  /// Logged classes, newest first (only [mixId]'s when given).
  Future<List<ClassSession>> classSessions({int? mixId}) async {
    final rows = await _db.query(
      'class_sessions',
      where: mixId == null ? null : 'mix_id = ?',
      whereArgs: mixId == null ? null : [mixId],
      orderBy: 'taught_at DESC, id DESC',
    );
    final items = <int, List<String>>{};
    for (final r in await _db.rawQuery(
      'SELECT i.session_id, i.path FROM class_session_items i '
      'JOIN class_sessions s ON s.id = i.session_id '
      '${mixId == null ? '' : 'WHERE s.mix_id = ? '}ORDER BY i.session_id, i.pos',
      [?mixId],
    )) {
      (items[r['session_id'] as int] ??= []).add(r['path'] as String);
    }
    return [
      for (final r in rows)
        ClassSession(
          r['id'] as int,
          mixId: r['mix_id'] as int?,
          mixName: (r['mix_name'] as String?) ?? '',
          taughtAt: DateTime.fromMillisecondsSinceEpoch(r['taught_at'] as int),
          source: (r['source'] as String?) ?? 'manual',
          paths: items[r['id']] ?? const [],
        ),
    ];
  }

  Future<void> deleteClassSession(int id) => _db.transaction((t) async {
    await t.delete('class_session_items', where: 'session_id = ?', whereArgs: [id]);
    await t.delete('class_sessions', where: 'id = ?', whereArgs: [id]);
  });

  /// When each saved mix was last taught, by mix id.
  Future<Map<int, DateTime>> lastTaught() async => {
    for (final r in await _db.rawQuery(
      'SELECT mix_id, MAX(taught_at) AS last '
      'FROM class_sessions WHERE mix_id IS NOT NULL GROUP BY mix_id',
    ))
      r['mix_id'] as int: DateTime.fromMillisecondsSinceEpoch(r['last'] as int),
  };

  /// How many weeks back a taught song counts as "recently taught" (setting
  /// `recent_weeks`, default [defaultRecentWeeks]).
  Future<int> recentWeeks() async {
    final n = int.tryParse(await setting('recent_weeks') ?? '');
    return n == null || n < 1 ? defaultRecentWeeks : n;
  }

  Future<void> setRecentWeeks(int weeks) => setSetting('recent_weeks', '$weeks');

  /// Songs taught in the last [recentWeeks] weeks (before [now]).
  Future<Set<String>> recentlyTaughtPaths({DateTime? now}) async =>
      pathsTaughtSince((now ?? DateTime.now()).subtract(Duration(days: 7 * await recentWeeks())));

  /// Every time [path] was in a taught class, newest first.
  Future<List<DateTime>> taughtDates(String path) async => [
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT s.id, s.taught_at FROM class_session_items i '
      'JOIN class_sessions s ON s.id = i.session_id WHERE i.path = ? '
      'ORDER BY s.taught_at DESC',
      [path],
    ))
      DateTime.fromMillisecondsSinceEpoch(r['taught_at'] as int),
  ];

  /// Songs in any class taught at or after [since].
  Future<Set<String>> pathsTaughtSince(DateTime since) async => {
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT i.path FROM class_session_items i '
      'JOIN class_sessions s ON s.id = i.session_id WHERE s.taught_at >= ?',
      [since.millisecondsSinceEpoch],
    ))
      r['path'] as String,
  };

  /// Every play (counted or not, any app) at or after [since], oldest first.
  Future<List<PlayRecord>> playsSince(DateTime since) async => [
    for (final r in await _db.query(
      'plays',
      columns: ['path', 'played_at', 'listened', 'completed'],
      where: 'played_at >= ?',
      whereArgs: [since.millisecondsSinceEpoch],
      orderBy: 'played_at',
    ))
      (
        path: r['path'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(r['played_at'] as int),
        listened: (r['listened'] as num?)?.toDouble() ?? 0,
        completed: r['completed'] == 1,
      ),
  ];

  /// The songs of every saved mix, in order, by mix id.
  Future<Map<int, List<String>>> allMixPaths() async {
    final out = <int, List<String>>{};
    for (final r in await _db.query('mix_items', orderBy: 'mix_id, pos')) {
      (out[r['mix_id'] as int] ??= []).add(r['path'] as String);
    }
    return out;
  }

  static const _dismissedKey = 'dismissed_class_suggestions';

  /// Keys (`mixId:yyyy-mm-dd`) of class suggestions the user dismissed.
  Future<Set<String>> dismissedClassSuggestions() async {
    try {
      return {...(jsonDecode(await setting(_dismissedKey) ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> dismissClassSuggestion(String key) async =>
      setSetting(_dismissedKey, jsonEncode([...await dismissedClassSuggestions(), key]));

  // ---- phone sync (sent tracks and path matching) ----

  /// Remembers which library file each sent package copy came from.
  Future<void> recordSentTracks(Iterable<({String sha256, String path})> tracks, {int? at}) async {
    final now = at ?? DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final t in tracks) {
      if (t.sha256.isEmpty || t.path.isEmpty) continue;
      batch.insert('sent_tracks', {
        'sha256': t.sha256,
        'path': t.path,
        'sent_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// The subset of [paths] that are library songs.
  Future<Set<String>> existingSongPaths(Iterable<String> paths) async {
    final out = <String>{};
    for (final c in _chunks(paths.toSet().toList())) {
      for (final r in await _db.query(
        'songs',
        columns: ['path'],
        where: 'path IN (${_marks(c.length)})',
        whereArgs: c,
      )) {
        out.add(r['path'] as String);
      }
    }
    return out;
  }

  /// Library paths of sent tracks by sha256 (only files still in `songs`).
  Future<Map<String, String>> sentTrackPaths(Iterable<String> shas) async {
    final out = <String, String>{};
    for (final c in _chunks(shas.toSet().toList())) {
      for (final r in await _db.rawQuery(
        'SELECT t.sha256, t.path FROM sent_tracks t JOIN songs s ON s.path = t.path '
        'WHERE t.sha256 IN (${_marks(c.length)})',
        c,
      )) {
        out[r['sha256'] as String] = r['path'] as String;
      }
    }
    return out;
  }

  /// Songs (path, duration) per [dupKeyFor] key; rows without a stored key
  /// are keyed from their title/artist.
  Future<Map<String, List<({String path, double? duration})>>> songsByDupKey(Iterable<String> keys) async {
    final want = keys.where((k) => k.isNotEmpty).toSet();
    final out = <String, List<({String path, double? duration})>>{};
    void add(String k, Map<String, Object?> r) =>
        (out[k] ??= []).add((path: r['path'] as String, duration: (r['duration'] as num?)?.toDouble()));
    for (final c in _chunks(want.toList())) {
      for (final r in await _db.query(
        'songs',
        columns: ['path', 'duration', 'dup_key'],
        where: 'dup_key IN (${_marks(c.length)})',
        whereArgs: c,
      )) {
        add(r['dup_key'] as String, r);
      }
    }
    if (want.isNotEmpty) {
      for (final r in await _db.query(
        'songs',
        columns: ['path', 'duration', 'title', 'artist'],
        where: 'dup_key IS NULL',
      )) {
        final k = dupKeyFor(r['artist'] as String?, r['title'] as String?);
        if (want.contains(k)) add(k, r);
      }
    }
    return out;
  }

  /// Play times (ms) per path, optionally only those logged by [app].
  Future<Map<String, List<int>>> playTimes(Iterable<String> paths, {String? app}) async {
    final out = <String, List<int>>{};
    for (final c in _chunks(paths.toSet().toList())) {
      for (final r in await _db.query(
        'plays',
        columns: ['path', 'played_at'],
        where: 'path IN (${_marks(c.length)})${app == null ? '' : ' AND app = ?'}',
        whereArgs: [...c, ?app],
      )) {
        final at = r['played_at'] as int?;
        if (at != null) (out[r['path'] as String] ??= []).add(at);
      }
    }
    return out;
  }

  // ---- library maintenance ----

  Future<List<Song>> allSongs() async =>
      _withTags(await _db.query('songs', orderBy: 'artist COLLATE NOCASE, album COLLATE NOCASE, path'));

  /// Lightweight ownership snapshot across all scanned roots, without lyrics
  /// or playback filters. Missing files remain owned until removed/rescanned.
  Future<List<Song>> albumCatalogSongs() async => [
    for (final r in await _db.query(
      'songs',
      columns: ['path', 'title', 'artist', 'album', 'track_no', 'track_total', 'disc_no', 'disc_total'],
      where: "album IS NOT NULL AND TRIM(album) <> ''",
      orderBy: 'artist COLLATE NOCASE, album COLLATE NOCASE, path',
    ))
      Song.fromRow(r),
  ];

  /// Every library path with its length (for playlist matching).
  Future<List<({String path, double? duration})>> songPathIndex() async => [
    for (final r in await _db.query('songs', columns: ['path', 'duration']))
      (path: r['path'] as String, duration: (r['duration'] as num?)?.toDouble()),
  ];

  /// The library songs at [paths] (with tags), keyed by path.
  Future<Map<String, Song>> songsAt(Iterable<String> paths) async {
    final out = <String, Song>{};
    for (final c in _chunks(paths.toSet().toList())) {
      for (final s in await _withTags(await _db.query('songs', where: 'path IN (${_marks(c.length)})', whereArgs: c))) {
        out[s.path] = s;
      }
    }
    return out;
  }

  /// Points every record of [from] at [to] (the file was moved).
  Future<void> renameSong(String from, String to) => _db.transaction((t) async {
    for (final tbl in ['songs', 'segments', 'song_tags', 'overrides', 'mix_items', 'plays', 'sent_tracks']) {
      await t.update(tbl, {'path': to}, where: 'path = ?', whereArgs: [from]);
    }
  });

  // ---- sharing bundle ----

  /// Ratings, favourites, tags, mixes and play history keyed by file path.
  Future<Map<String, Object?>> exportBundle() async {
    final songs = <String, Object?>{};
    for (final r in await _db.query('songs', columns: ['path', 'rating', 'fav'], where: 'rating > 0 OR fav = 1')) {
      songs[r['path'] as String] = {'rating': r['rating'], 'fav': r['fav'] == 1};
    }
    for (final r in await _db.query('song_tags')) {
      final e = songs.putIfAbsent(r['path'] as String, () => <String, Object?>{}) as Map<String, Object?>;
      ((e['tags'] ??= <Object?>[]) as List).add(r['tag']);
    }
    final mixList = <Map<String, Object?>>[
      for (final m in await mixes()) {'name': m.name, 'paths': await mixPaths(m.id)},
    ];
    final plays = [
      for (final r in await _db.query('plays'))
        {
          'path': r['path'],
          'at': r['played_at'],
          'listened': r['listened'],
          'done': r['completed'] == 1,
          'app': r['app'],
        },
    ];
    return {'version': 1, 'songs': songs, 'mixes': mixList, 'plays': plays};
  }

  /// Merges a bundle: the higher rating wins, favourites/tags are added,
  /// existing mixes are kept, plays are deduplicated.
  Future<BundleResult> importBundle(Map<String, dynamic> b) async {
    var songsTouched = 0, mixesAdded = 0;
    final songs = (b['songs'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final e in songs.entries) {
      if (await song(e.key) == null) continue;
      final v = (e.value as Map).cast<String, dynamic>();
      final rating = (v['rating'] as num?)?.toInt() ?? 0;
      await _db.rawUpdate('UPDATE songs SET rating = MAX(rating, ?), fav = MAX(fav, ?) WHERE path = ?', [
        rating.clamp(0, 5),
        v['fav'] == true ? 1 : 0,
        e.key,
      ]);
      for (final t in (v['tags'] as List?) ?? const []) {
        await addTag(e.key, t as String);
      }
      songsTouched++;
    }
    final have = {for (final m in await mixes()) m.name};
    for (final m in (b['mixes'] as List?) ?? const []) {
      final name = (m as Map)['name'] as String;
      if (have.contains(name)) continue;
      final paths = <String>[
        for (final p in (m['paths'] as List))
          if (await song(p as String) != null) p,
      ];
      if (paths.isEmpty) continue;
      await saveMix(name, paths);
      mixesAdded++;
    }
    final plays = await importPlays([
      for (final p in (b['plays'] as List?) ?? const []) (p as Map).cast<String, Object?>(),
    ]);
    return BundleResult(songsTouched, mixesAdded, plays);
  }
}

class PlayStat {
  const PlayStat(this.path, this.plays, this.skips, this.lastPlayed);
  final String path;
  final int plays;
  final int skips;
  final int? lastPlayed;
}

class BundleResult {
  const BundleResult(this.songs, this.mixes, this.plays);
  final int songs;
  final int mixes;
  final int plays;
}

/// Mixes removed by [MusicDb.deleteMixes], for undo.
class DeletedMixes {
  DeletedMixes._(this._mixes, this._items, this._tags);
  final List<Map<String, Object?>> _mixes, _items, _tags;
  int get count => _mixes.length;
  List<int> get ids => [for (final m in _mixes) m['id'] as int];
}

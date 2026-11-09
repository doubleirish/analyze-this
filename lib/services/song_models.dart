// Library data types shared by the database, controllers and screens.
import 'dart:convert';

import 'package:shared_core/shared_core.dart';

/// Default for the `recent_weeks` setting: songs taught this many weeks back
/// count as recently taught (hidden by the Songs filter, avoided by fills).
const defaultRecentWeeks = 6;

class Song {
  Song({
    required this.path,
    this.size = 0,
    this.mtime = 0,
    this.title,
    this.artist,
    this.album,
    this.year,
    this.genre,
    this.duration,
    this.avgBpm,
    this.medianBpm,
    this.minBpm,
    this.maxBpm,
    this.bpmStddev,
    this.lyrics,
    this.lyricsChecked = false,
    this.mbChecked = false,
    this.yearChecked = false,
    this.rating = 0,
    this.explicit = false,
    this.dupKey,
    this.userTags = const [],
    this.fav = false,
    this.addedAt,
    this.genreSrc,
    this.trackNo,
    this.trackTotal,
    this.discNo,
    this.discTotal,
    this.tagsV = 0,
    this.loudness,
    this.trimStart,
    this.trimEnd,
    this.explicitManual,
    this.lastMixed,
  });

  /// Integrated loudness in LUFS (mono mix-down), measured during analysis.
  final double? loudness;

  /// Where play starts and stops (seconds); null = the file's start / end.
  final double? trimStart;
  final double? trimEnd;

  /// The user's explicit / clean mark; null = use the lyrics check ([explicit]).
  final bool? explicitManual;

  /// When the song was last saved or sent in a mix (ms since epoch).
  final int? lastMixed;

  /// Explicit after the user's mark: what filters and badges use.
  bool get isExplicit => explicitManual ?? explicit;

  bool get trimmed => trimStart != null || trimEnd != null;

  /// Seconds that actually play (the trimmed length); null when unknown.
  double? get playSeconds {
    final d = duration;
    if (d == null) return null;
    final end = (trimEnd ?? d).clamp(0.0, d);
    final start = (trimStart ?? 0).clamp(0.0, end);
    return end - start;
  }

  /// Track/disc position from the file's tags (null when untagged).
  final int? trackNo;
  final int? trackTotal;
  final int? discNo;
  final int? discTotal;

  /// 1 once the tags have been read with track/disc numbers; lets a rescan
  /// refresh rows stored before those columns existed.
  final int tagsV;

  /// Null when [genre] is the song's own (tags, API, manual edit); 'album' or
  /// 'artist' when it was inherited from the album/artist genre list.
  final String? genreSrc;

  /// The song's own genre, ignoring one inherited from the album/artist lists.
  String? get ownGenre => genreSrc == null ? genre : null;

  final bool fav;

  /// When the song first entered the database (ms since epoch).
  final int? addedAt;
  final String path;
  final int size;
  final int mtime;
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final String? genre;
  final double? duration;
  final double? avgBpm;
  final double? medianBpm;
  final double? minBpm;
  final double? maxBpm;

  /// Duration-weighted spread of the tempo; low means a steady song.
  final double? bpmStddev;
  final String? lyrics;
  final bool lyricsChecked;
  final bool mbChecked;
  final bool yearChecked;
  final int rating;
  final bool explicit;
  final String? dupKey;
  final List<String> userTags;

  bool get hasLyrics => lyrics != null && lyrics!.trim().isNotEmpty;

  /// Tagged [corruptTag] by a damage check (or by hand): kept out of mixes.
  bool get damaged => userTags.contains(corruptTag);

  String get display =>
      [if (artist != null) artist, title ?? path.split(RegExp(r'[\\/]')).last]
          .join(' - ');

  /// The row; [user] adds the user-owned columns (trim, explicit mark, last
  /// mixed) that a rescan must not overwrite (see [MusicDb.upsertSong]).
  Map<String, Object?> toRow({bool user = true}) => {
        'path': path,
        'size': size,
        'mtime': mtime,
        'title': title,
        'artist': artist,
        'album': album,
        'year': year,
        'genre': genre,
        'duration': duration,
        'avg_bpm': avgBpm,
        'median_bpm': medianBpm,
        'min_bpm': minBpm,
        'max_bpm': maxBpm,
        'bpm_stddev': bpmStddev,
        'lyrics': lyrics,
        'lyrics_checked': lyricsChecked ? 1 : 0,
        'mb_checked': mbChecked ? 1 : 0,
        'year_checked': yearChecked ? 1 : 0,
        'rating': rating,
        'explicit': explicit ? 1 : 0,
        'dup_key': dupKey,
        'fav': fav ? 1 : 0,
        'added_at': addedAt,
        'genre_src': genreSrc,
        'track_no': trackNo,
        'track_total': trackTotal,
        'disc_no': discNo,
        'disc_total': discTotal,
        'tags_v': tagsV,
        'loudness': loudness,
        if (user) ...{
          'trim_start': trimStart,
          'trim_end': trimEnd,
          'explicit_manual': explicitManual == null ? null : (explicitManual! ? 1 : 0),
          'last_mixed': lastMixed,
        },
      };

  factory Song.fromRow(Map<String, Object?> r, [List<String> tags = const []]) =>
      Song(
        path: r['path'] as String,
        size: (r['size'] as int?) ?? 0,
        mtime: (r['mtime'] as int?) ?? 0,
        title: r['title'] as String?,
        artist: r['artist'] as String?,
        album: r['album'] as String?,
        year: r['year'] as int?,
        genre: r['genre'] as String?,
        duration: (r['duration'] as num?)?.toDouble(),
        avgBpm: (r['avg_bpm'] as num?)?.toDouble(),
        medianBpm: (r['median_bpm'] as num?)?.toDouble(),
        minBpm: (r['min_bpm'] as num?)?.toDouble(),
        maxBpm: (r['max_bpm'] as num?)?.toDouble(),
        bpmStddev: (r['bpm_stddev'] as num?)?.toDouble(),
        lyrics: r['lyrics'] as String?,
        lyricsChecked: r['lyrics_checked'] == 1,
        mbChecked: r['mb_checked'] == 1,
        yearChecked: r['year_checked'] == 1,
        rating: (r['rating'] as int?) ?? 0,
        explicit: r['explicit'] == 1,
        dupKey: r['dup_key'] as String?,
        userTags: tags,
        fav: r['fav'] == 1,
        addedAt: r['added_at'] as int?,
        genreSrc: r['genre_src'] as String?,
        trackNo: r['track_no'] as int?,
        trackTotal: r['track_total'] as int?,
        discNo: r['disc_no'] as int?,
        discTotal: r['disc_total'] as int?,
        tagsV: (r['tags_v'] as int?) ?? 0,
        loudness: (r['loudness'] as num?)?.toDouble(),
        trimStart: (r['trim_start'] as num?)?.toDouble(),
        trimEnd: (r['trim_end'] as num?)?.toDouble(),
        explicitManual: r['explicit_manual'] == null ? null : r['explicit_manual'] == 1,
        lastMixed: r['last_mixed'] as int?,
      );

  Song copyWith({int? rating, bool? fav}) => Song(
        fav: fav ?? this.fav,
        addedAt: addedAt,
        path: path,
        size: size,
        mtime: mtime,
        title: title,
        artist: artist,
        album: album,
        year: year,
        genre: genre,
        duration: duration,
        avgBpm: avgBpm,
        medianBpm: medianBpm,
        minBpm: minBpm,
        maxBpm: maxBpm,
        bpmStddev: bpmStddev,
        lyrics: lyrics,
        lyricsChecked: lyricsChecked,
        mbChecked: mbChecked,
        yearChecked: yearChecked,
        rating: rating ?? this.rating,
        explicit: explicit,
        dupKey: dupKey,
        genreSrc: genreSrc,
        trackNo: trackNo,
        trackTotal: trackTotal,
        discNo: discNo,
        discTotal: discTotal,
        tagsV: tagsV,
        loudness: loudness,
        trimStart: trimStart,
        trimEnd: trimEnd,
        explicitManual: explicitManual,
        lastMixed: lastMixed,
      );
}

enum SongSort { artist, title, bpm, steadiness, rating, duration, added, random }

/// System tag on songs whose audio is damaged (see [MusicDb.recordHealth]).
const corruptTag = 'corrupt';

/// Last damage-check result for one file.
class SongHealth {
  const SongHealth(this.path, this.status, {this.reason, this.depth, this.checkedAt, this.size, this.mtime});
  final String path;

  /// 'damaged', 'ok', or 'override' (flagged, but the user said it plays fine).
  final String status;
  final String? reason;

  /// 'quick', 'deep', 'decode' (the analyser couldn't read it) or 'manual'.
  final String? depth;
  final int? checkedAt;
  final int? size;
  final int? mtime;
  bool get damaged => status == 'damaged';
}

class SongQuery {
  const SongQuery({
    this.text = '',
    this.lyrics = '',
    this.lyricsAny = const [],
    this.lyricsAll = const [],
    this.lyricsNot = const [],
    this.anyIncludesTitle = false,
    this.minBpm,
    this.maxBpm,
    this.targetRpm,
    this.rpmTolerance = 5,
    this.halfDouble = true,
    this.maxStddev,
    this.minSeconds,
    this.maxSeconds,
    this.genre = '',
    this.decade,
    this.tag = '',
    this.lyricsOnly = false,
    this.hideExplicit = false,
    this.hideUsed = false,
    this.hideInLastMixes = 0,
    this.exceptMix,
    this.hideCorrupt = false,
    this.hideTaughtWithinDays,
    this.minRating = 0,
    this.sort = SongSort.artist,
    this.exclude = const {},
    this.limit = 500,
    this.artist = '',
    this.album = '',
    this.exactNames = false,
    this.favOnly = false,
    this.addedSince,
    this.minYear,
    this.maxYear,
  });

  final int? minYear;
  final int? maxYear;

  /// Artist / album filters. Substring match, or the whole name when
  /// [exactNames] (used when drilling into one artist or album).
  final String artist;
  final String album;
  final bool exactNames;
  final bool favOnly;

  /// Only songs added to the database at or after this time (ms since epoch).
  final int? addedSince;

  /// Matches title, artist, album or path.
  final String text;

  /// Matches this exact phrase inside the lyrics.
  final String lyrics;

  /// Lyrics must contain at least one of these (or the title, if
  /// [anyIncludesTitle]).
  final List<String> lyricsAny;

  /// Lyrics must contain every one of these.
  final List<String> lyricsAll;

  /// Lyrics must contain none of these.
  final List<String> lyricsNot;
  final bool anyIncludesTitle;
  final double? minBpm;
  final double? maxBpm;

  /// Cadence match on the median tempo; also half and double time if [halfDouble].
  final double? targetRpm;
  final double rpmTolerance;
  final bool halfDouble;
  final double? maxStddev;
  final double? minSeconds;
  final double? maxSeconds;
  final String genre;
  final int? decade;
  final String tag;
  final bool lyricsOnly;
  final bool hideExplicit;

  /// Hide songs that already appear in a saved mix.
  final bool hideUsed;

  /// Hide songs used in any of this many most recently saved mixes, other
  /// than [exceptMix] (the mix being edited); 0 = off.
  final int hideInLastMixes;
  final int? exceptMix;

  /// Hide songs tagged [corruptTag] (always on when picking songs for a mix).
  final bool hideCorrupt;

  /// Hide songs in a class taught within this many days (null = show all).
  final int? hideTaughtWithinDays;
  final int minRating;
  final SongSort sort;
  final Set<String> exclude;
  final int limit;

  SongQuery copyWith({
    double? minBpm,
    double? maxBpm,
    double? targetRpm,
    double? rpmTolerance,
    double? maxStddev,
    double? minSeconds,
    double? maxSeconds,
    bool clearTempo = false,
    bool clearDuration = false,
    Set<String>? exclude,
    int? limit,
    SongSort? sort,
    String? artist,
    String? album,
    bool? exactNames,
    bool? hideUsed,
    int? hideInLastMixes,
    bool? hideCorrupt,
    int? hideTaughtWithinDays,
    bool? favOnly,
    int? addedSince,
    String? genre,
    int? minYear,
    int? maxYear,
    bool clearYears = false,
  }) =>
      SongQuery(
        minYear: clearYears ? minYear : minYear ?? this.minYear,
        maxYear: clearYears ? maxYear : maxYear ?? this.maxYear,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        exactNames: exactNames ?? this.exactNames,
        favOnly: favOnly ?? this.favOnly,
        addedSince: addedSince ?? this.addedSince,
        text: text,
        lyrics: lyrics,
        lyricsAny: lyricsAny,
        lyricsAll: lyricsAll,
        lyricsNot: lyricsNot,
        anyIncludesTitle: anyIncludesTitle,
        minBpm: clearTempo ? minBpm : minBpm ?? this.minBpm,
        maxBpm: clearTempo ? maxBpm : maxBpm ?? this.maxBpm,
        targetRpm: clearTempo ? targetRpm : targetRpm ?? this.targetRpm,
        rpmTolerance: rpmTolerance ?? this.rpmTolerance,
        halfDouble: halfDouble,
        maxStddev: clearTempo ? maxStddev : maxStddev ?? this.maxStddev,
        minSeconds: clearDuration ? minSeconds : minSeconds ?? this.minSeconds,
        maxSeconds: clearDuration ? maxSeconds : maxSeconds ?? this.maxSeconds,
        genre: genre ?? this.genre,
        decade: decade,
        tag: tag,
        lyricsOnly: lyricsOnly,
        hideExplicit: hideExplicit,
        hideUsed: hideUsed ?? this.hideUsed,
        hideInLastMixes: hideInLastMixes ?? this.hideInLastMixes,
        exceptMix: exceptMix,
        hideCorrupt: hideCorrupt ?? this.hideCorrupt,
        hideTaughtWithinDays: hideTaughtWithinDays ?? this.hideTaughtWithinDays,
        minRating: minRating,
        sort: sort ?? this.sort,
        exclude: exclude ?? this.exclude,
        limit: limit ?? this.limit,
      );

  /// For saving as a smart playlist (excludes and limit are not saved).
  Map<String, Object?> toJson() => {
        'text': text,
        'artist': artist,
        'album': album,
        'exact': exactNames,
        'lyrics': lyrics,
        'any': lyricsAny,
        'all': lyricsAll,
        'not': lyricsNot,
        'anyTitle': anyIncludesTitle,
        'minBpm': minBpm,
        'maxBpm': maxBpm,
        'rpm': targetRpm,
        'tol': rpmTolerance,
        'halfDouble': halfDouble,
        'std': maxStddev,
        'minSec': minSeconds,
        'maxSec': maxSeconds,
        'genre': genre,
        'decade': decade,
        'tag': tag,
        'lyricsOnly': lyricsOnly,
        'hideExplicit': hideExplicit,
        'hideUsed': hideUsed,
        'hideCorrupt': hideCorrupt,
        'taughtDays': hideTaughtWithinDays,
        'fav': favOnly,
        'addedSince': addedSince,
        'minYear': minYear,
        'maxYear': maxYear,
        'minRating': minRating,
        'sort': sort.name,
      };

  factory SongQuery.fromJson(Map<String, dynamic> j) {
    List<String> l(String k) => [for (final e in (j[k] as List? ?? const [])) '$e'];
    double? d(String k) => (j[k] as num?)?.toDouble();
    return SongQuery(
      text: j['text'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      album: j['album'] as String? ?? '',
      exactNames: j['exact'] as bool? ?? false,
      lyrics: j['lyrics'] as String? ?? '',
      lyricsAny: l('any'),
      lyricsAll: l('all'),
      lyricsNot: l('not'),
      anyIncludesTitle: j['anyTitle'] as bool? ?? false,
      minBpm: d('minBpm'),
      maxBpm: d('maxBpm'),
      targetRpm: d('rpm'),
      rpmTolerance: d('tol') ?? 5,
      halfDouble: j['halfDouble'] as bool? ?? true,
      maxStddev: d('std'),
      minSeconds: d('minSec'),
      maxSeconds: d('maxSec'),
      genre: j['genre'] as String? ?? '',
      decade: j['decade'] as int?,
      tag: j['tag'] as String? ?? '',
      lyricsOnly: j['lyricsOnly'] as bool? ?? false,
      hideExplicit: j['hideExplicit'] as bool? ?? false,
      hideUsed: j['hideUsed'] as bool? ?? false,
      hideCorrupt: j['hideCorrupt'] as bool? ?? false,
      hideTaughtWithinDays: j['taughtDays'] as int?,
      favOnly: j['fav'] as bool? ?? false,
      addedSince: j['addedSince'] as int?,
      minYear: j['minYear'] as int?,
      maxYear: j['maxYear'] as int?,
      minRating: j['minRating'] as int? ?? 0,
      sort: SongSort.values.firstWhere((s) => s.name == j['sort'],
          orElse: () => SongSort.artist),
    );
  }
}

class SmartList {
  const SmartList(this.id, this.name, this.query);
  final int id;
  final String name;
  final SongQuery query;
}

/// How much of a group of songs (an artist, album or genre) has each kind of
/// data. `found` counts songs that have it; `checked` counts songs whose
/// lookup ran and found nothing, so a later scan would not retry them.
class Coverage {
  const Coverage({
    this.songs = 0,
    this.bpm = 0,
    this.bpmChecked = 0,
    this.lyrics = 0,
    this.lyricsChecked = 0,
    this.year = 0,
    this.yearChecked = 0,
    this.genre = 0,
    this.genreChecked = 0,
  });
  static const empty = Coverage();

  final int songs;
  final int bpm, bpmChecked;
  final int lyrics, lyricsChecked;
  final int year, yearChecked;
  final int genre, genreChecked;

  /// Reads the columns of `Db.coverageCols`.
  factory Coverage.fromRow(Map<String, Object?> r) {
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    return Coverage(
      songs: n('songs'),
      bpm: n('cov_bpm'),
      bpmChecked: n('cov_bpm_chk'),
      lyrics: n('cov_lyr'),
      lyricsChecked: n('cov_lyr_chk'),
      year: n('cov_yr'),
      yearChecked: n('cov_yr_chk'),
      genre: n('cov_gen'),
      genreChecked: n('cov_gen_chk'),
    );
  }

  /// Share of songs (0 to 1) that have the data.
  double share(int found) => songs == 0 ? 0 : found / songs;

  double get bpmShare => share(bpm);
  double get lyricsShare => share(lyrics);
  double get yearShare => share(year);
  double get genreShare => share(genre);

  /// Average of the four found shares.
  double get overall => (bpmShare + lyricsShare + yearShare + genreShare) / 4;
}

class ArtistInfo {
  const ArtistInfo(this.name, this.songs, this.albums, this.samplePath,
      {this.minBpm, this.maxBpm, this.used = 0, this.coverage = Coverage.empty});
  final Coverage coverage;
  final String name;
  final int songs;
  final int albums;

  /// A song by this artist, used to borrow album art.
  final String samplePath;
  final double? minBpm;
  final double? maxBpm;

  /// How many of their songs appear in saved mixes.
  final int used;
}

class GenreInfo {
  const GenreInfo(this.name, this.songs, this.artists, this.albums,
      [this.samples = const [], this.coverage = Coverage.empty]);
  final Coverage coverage;
  final String name;
  final int songs;
  final int artists;
  final int albums;

  /// Paths of songs from up to four different albums, for cover art.
  final List<String> samples;
}

class AlbumInfo {
  const AlbumInfo(this.album, this.artist, this.songs, this.samplePath,
      {this.year, this.minBpm, this.maxBpm, this.coverage = Coverage.empty,
      this.favs = 0, this.totalSecs, this.synthetic = false});
  final Coverage coverage;
  final String album;
  final String? artist;
  final int songs;
  final String samplePath;
  final int? year;
  final double? minBpm;
  final double? maxBpm;
  final int favs;
  final double? totalSecs;
  final bool synthetic;

  /// Local-library heuristic, not an authoritative release type.
  bool get isMinor => !synthetic &&
      (songs <= 6 || (totalSecs != null && totalSecs! < 1800));
}

List<AlbumInfo> sortArtistAlbums(Iterable<AlbumInfo> albums) => [...albums]
  ..sort((a, b) {
    if (a.synthetic != b.synthetic) return a.synthetic ? -1 : 1;
    final favs = b.favs.compareTo(a.favs);
    if (favs != 0) return favs;
    if (a.year != b.year) {
      if (a.year == null) return 1;
      if (b.year == null) return -1;
      return b.year!.compareTo(a.year!);
    }
    return a.album.toLowerCase().compareTo(b.album.toLowerCase());
  });

class LibraryStats {
  const LibraryStats({
    required this.total,
    required this.withBpm,
    required this.withLyrics,
    required this.withGenre,
    required this.favourites,
    required this.bpmBuckets,
    required this.decades,
    required this.genres,
  });
  final int total;
  final int withBpm;
  final int withLyrics;
  final int withGenre;
  final int favourites;

  /// Lower bound of each 10-BPM bucket -> songs.
  final Map<int, int> bpmBuckets;
  final Map<int, int> decades;
  final List<MapEntry<String, int>> genres;
}

/// How alike two songs are for "more like this" (higher = closer).
double similarity(Song a, Song b) {
  var s = 0.0;
  final x = a.medianBpm, y = b.medianBpm;
  if (x != null && y != null) {
    var d = (x - y).abs();
    for (final f in [x * 2, x / 2]) {
      final e = (f - y).abs() + 3; // half/double time works, but a bit less well
      if (e < d) d = e;
    }
    s += (6 - d).clamp(0, 6) * 0.7;
  }
  bool same(String? p, String? q) =>
      p != null && q != null && p.trim().toLowerCase() == q.trim().toLowerCase();
  if (same(a.artist, b.artist)) s += 2;
  if (same(a.genre, b.genre)) s += 2;
  if (a.year != null && b.year != null && a.year! ~/ 10 == b.year! ~/ 10) s += 1.5;
  if (same(a.album, b.album)) s += 0.5;
  return s;
}

class MixInfo {
  MixInfo(this.id, this.name, {this.savedAt, this.programJson});
  final int id;
  final String name;

  /// When the mix was last saved (ms since epoch), if known.
  final int? savedAt;

  /// The program (as JSON) this mix was built from, if known. Lets a
  /// reloaded mix match its songs back to the right part names/ranges
  /// instead of whatever program happens to be selected at the time.
  final String? programJson;
}

/// A saved mix with the totals the saved-mixes manager shows.
class MixSummary extends MixInfo {
  MixSummary(super.id, super.name,
      {super.savedAt,
      super.programJson,
      this.songCount = 0,
      this.totalSeconds = 0,
      this.icon,
      this.pinned = false,
      this.archived = false,
      this.lastOpened,
      this.tags = const []});

  final int songCount;

  /// Chosen icon; null shows a collage of the mix's album art.
  final MixIconSpec? icon;
  final bool pinned, archived;

  /// When it was last loaded into the Mix tab (ms since epoch).
  final int? lastOpened;

  /// Free-form labels for grouping mixes (sorted).
  final List<String> tags;

  /// Sum of the lengths of the mix's songs that are still in the library.
  final double totalSeconds;

  /// Name of the program the mix was built from, if it was saved with one.
  String? get programName {
    final j = programJson;
    if (j == null) return null;
    try {
      return (jsonDecode(j) as Map<String, dynamic>)['name'] as String?;
    } catch (_) {
      return null;
    }
  }
}

/// A logged class: when a mix was taught, with a snapshot of its songs.
class ClassSession {
  ClassSession(this.id,
      {this.mixId,
      required this.mixName,
      required this.taughtAt,
      this.source = 'manual',
      this.paths = const []});
  final int id;

  /// The saved mix it was taught from (null for an unsaved mix; may point at
  /// a mix that has since been deleted).
  final int? mixId;
  final String mixName;
  final DateTime taughtAt;

  /// 'manual' (Mark as taught) or 'auto' (an accepted play-history suggestion).
  final String source;

  /// The mix's songs in order at the time it was logged.
  final List<String> paths;
}

/// A play as stored in history (any app), for the class detector.
typedef PlayRecord = ({String path, DateTime at, double listened, bool completed});

/// Thrown when renaming/duplicating a mix to a name another mix already has.
class MixNameTaken implements Exception {
  MixNameTaken(this.name);
  final String name;
  @override
  String toString() => 'A saved mix named "$name" already exists';
}

class TempoSeg {
  const TempoSeg(this.start, this.end, this.bpm);
  final double start;
  final double end;
  final double bpm;
}

const defaultExplicitWords = [
  'fuck', 'shit', 'bitch', 'asshole', 'bastard', 'cunt', 'dick', 'pussy', 'whore',
  'nigga', 'nigger', 'motherfucker', 'goddamn',
];

/// Folder part of [path] (either separator).
String dirOf(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? '' : path.substring(0, i).toLowerCase();
}

/// Songs sharing an artist and title; [keeper] is the suggested copy to keep.
class DupGroup {
  DupGroup(this.songs, this.dirCounts, this.keeper);
  final List<Song> songs;
  final List<int> dirCounts;
  final int keeper;

  factory DupGroup.rank(List<Song> songs, Map<String, int> dirCounts) {
    final counts = [for (final s in songs) dirCounts[dirOf(s.path)] ?? 1];
    var best = 0;
    for (var i = 1; i < songs.length; i++) {
      final a = songs[i], b = songs[best];
      final c = counts[i].compareTo(counts[best]);
      final better = c != 0
          ? c > 0
          : a.size != b.size
              ? a.size > b.size
              : (a.duration ?? 0) > (b.duration ?? 0);
      if (better) best = i;
    }
    return DupGroup(songs, counts, best);
  }

  List<Song> get suggestedRemovals => [
        for (var i = 0; i < songs.length; i++)
          if (i != keeper) songs[i]
      ];
}

/// Title of an artist's synthetic "Best of" album (see best_of.dart).
String bestOfTitle(String artist) => '$artist: Best of';

/// Lower-case letters and digits only, so "Don't Stop" matches "Dont Stop".
String dupKeyFor(String? artist, String? title) {
  String n(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final a = n(artist), t = n(title);
  return t.isEmpty ? '' : '$a|$t';
}

/// True if [lyrics] contains any of [words] as a whole word.
bool containsExplicit(String? lyrics, Iterable<String> words) {
  if (lyrics == null || lyrics.isEmpty) return false;
  final ws = [for (final w in words) if (w.trim().isNotEmpty) RegExp.escape(w.trim())];
  if (ws.isEmpty) return false;
  return RegExp('\\b(${ws.join('|')})', caseSensitive: false).hasMatch(lyrics);
}

/// First lyric line containing any of [terms], for showing why a song matched.
String? lyricSnippet(String? lyrics, List<String> terms) {
  if (lyrics == null || terms.isEmpty) return null;
  final ts = [for (final t in terms) if (t.trim().isNotEmpty) t.trim().toLowerCase()];
  for (final line in lyrics.split('\n')) {
    final l = line.toLowerCase();
    if (ts.any(l.contains)) return line.trim();
  }
  return null;
}

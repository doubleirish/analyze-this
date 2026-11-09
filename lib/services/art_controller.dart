import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

/// Artist photos (Deezer, cached on disk) and bulk cover-art downloads.
/// A single album cover is fetched by [PlaybackController.downloadAlbumArt],
/// so the player's own art widgets see it too.
class ArtController extends ChangeNotifier {
  ArtController(this.playback, {required this.net, this._artistArt});

  final PlaybackController playback;
  final PoliteHttp net;

  ArtistArt? _artistArt;
  final Map<String, File?> artistImages = {};
  final Map<String, int> artistImageVersions = {};
  final Set<String> _artistLoading = {};

  /// Artist keys ([ArtistArt.keyFor]) whose photo is being downloaded.
  final Set<String> artistBusy = {};

  Future<ArtistArt> _art() async {
    if (_artistArt != null) return _artistArt!;
    final dir = await getApplicationSupportDirectory();
    return _artistArt =
        ArtistArt(Directory('${dir.path}${Platform.pathSeparator}artist_art'), net: net);
  }

  /// Loads an artist's photo into [artistImages] (disk cache first, then Deezer).
  Future<void> ensureArtistImage(String artist) async {
    final k = ArtistArt.keyFor(artist);
    if (k.isEmpty || artistBusy.contains(k) ||
        artistImages.containsKey(k) || !_artistLoading.add(k)) {
      return;
    }
    try {
      final art = await _art();
      var f = await art.cached(artist);
      if (artistBusy.contains(k)) return;
      f ??= await art.fetch(artist);
      if (!artistBusy.contains(k)) artistImages[k] = f;
    } catch (_) {
      if (!artistBusy.contains(k)) artistImages[k] = null;
    } finally {
      _artistLoading.remove(k);
      notifyListeners();
    }
  }

  /// Forces a Deezer photo lookup, retrying artists previously remembered as a miss.
  Future<bool> downloadArtistPhoto(String artist) async {
    final k = ArtistArt.keyFor(artist);
    if (k.isEmpty || !artistBusy.add(k)) return false;
    notifyListeners();
    try {
      final f = await (await _art()).fetch(artist, force: true);
      artistImages[k] = f;
      return f != null;
    } catch (_) {
      return false;
    } finally {
      artistBusy.remove(k);
      notifyListeners();
    }
  }

  Future<void> _changePhoto(
      String artist, Future<File?> Function(ArtistArt art) change) async {
    final k = ArtistArt.keyFor(artist);
    if (k.isEmpty) throw ArgumentError.value(artist, 'artist');
    if (!artistBusy.add(k)) throw StateError('An artist photo change is already running');
    notifyListeners();
    try {
      final art = await _art();
      // Wait for an automatic fetch before replacing its cached file.
      await art.waitForFetch(artist);
      final old = artistImages[k] ?? await art.cached(artist);
      final replacement = await change(art);
      if (old != null) await FileImage(old).evict();
      artistImages[k] = replacement;
      artistImageVersions[k] = (artistImageVersions[k] ?? 0) + 1;
    } finally {
      artistBusy.remove(k);
      notifyListeners();
    }
  }

  Future<void> useAlbumCoverAsArtistPhoto(String artist, String samplePath) =>
      _changePhoto(artist, (art) async {
        await playback.ensureMedia(samplePath);
        var cover = playback.media[samplePath]?.art;
        if (cover == null && playback.supportsArtDownload) {
          await playback.downloadAlbumArt(samplePath);
          cover = playback.media[samplePath]?.art;
        }
        if (cover == null) throw StateError('No cover is available for this album');
        return art.setFromBytes(artist, await cover.readAsBytes());
      });

  Future<void> randomOnlineArtistPhoto(String artist) =>
      _changePhoto(artist, (art) async {
        final current = await art.cached(artist);
        final bytes = current == null ? null : await current.readAsBytes();
        final urls = await art.candidates(artist)..shuffle();
        for (final url in urls) {
          final candidate = await art.imageBytes(url);
          if (bytes != null && listEquals(bytes, candidate)) continue;
          return art.setFromBytes(artist, candidate);
        }
        throw StateError('Deezer has no different matching artist photo. Choose an album cover instead.');
      });

  Future<void> resetArtistPhoto(String artist) =>
      _changePhoto(artist, (art) async {
        final urls = await art.candidates(artist);
        if (urls.isNotEmpty) return art.setFromUrl(artist, urls.first);
        await art.clear(artist);
        return null;
      });

  /// Bulk download status, e.g. "Album art 3/20"; null when idle.
  String? artProgress;

  bool hasEmbeddedArt(String samplePath) => playback.media[samplePath]?.art != null;

  /// Downloads art for every album in [samples] (a song path per album) that has none.
  Future<int> downloadMissingAlbumArt(List<String> samples) async {
    if (artProgress != null) return 0;
    var found = 0, i = 0;
    try {
      for (final p in samples) {
        artProgress = 'Album art ${++i}/${samples.length}';
        notifyListeners();
        await playback.ensureMedia(p);
        if (hasEmbeddedArt(p)) continue;
        if (await playback.downloadAlbumArt(p)) found++;
      }
    } finally {
      artProgress = null;
      notifyListeners();
    }
    return found;
  }

  /// Retries the photo of every artist in [names] that has none.
  Future<int> downloadMissingArtistPhotos(List<String> names) async {
    if (artProgress != null) return 0;
    var found = 0, i = 0;
    try {
      for (final n in names) {
        artProgress = 'Artist photos ${++i}/${names.length}';
        notifyListeners();
        if (artistImages[ArtistArt.keyFor(n)] != null) continue;
        if (await downloadArtistPhoto(n)) found++;
      }
    } finally {
      artProgress = null;
      notifyListeners();
    }
    return found;
  }
}

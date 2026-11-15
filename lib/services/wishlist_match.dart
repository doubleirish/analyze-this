import 'best_of.dart';
import 'song_models.dart';
import 'wishlist_parse.dart';

enum WishStatus { owned, damaged, missing, ambiguous }

class WishResult {
  const WishResult(this.entry, this.status, this.songs);

  final WishEntry entry;
  final WishStatus status;
  final List<Song> songs;
}

String wishArtistKey(String? artist) {
  final original = (artist ?? '').toLowerCase().trim();
  var s = original;
  s = s.replaceFirst(RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+.*$'), '');
  s = s.replaceFirst(RegExp(r'^the\s+'), '');
  final key = s.replaceAll(RegExp(r'[^a-z0-9]'), '');
  return key.isEmpty ? original : key;
}

String _wishTitleKey(String? title) {
  final key = titleKey(title);
  return key.isEmpty ? (title ?? '').trim().toLowerCase() : key;
}

/// Exact title/version matches are definitive. Broader title or artist
/// matches remain suggestions, never evidence of a healthy replacement.
List<WishResult> matchWishlist(List<WishEntry> entries, Iterable<Song> songs) {
  final byTitle = <String, List<Song>>{};
  for (final song in songs) {
    final key = _wishTitleKey(song.title);
    if (key.isNotEmpty) (byTitle[key] ??= []).add(song);
  }
  return [
    for (final entry in entries)
      () {
        final artist = wishArtistKey(entry.artist);
        final candidates =
            (byTitle[_wishTitleKey(entry.title)] ?? const <Song>[])
                .where(
                  (s) => artist.isEmpty || wishArtistKey(s.artist) == artist,
                )
                .toList();
        if (candidates.isEmpty) {
          return WishResult(entry, WishStatus.missing, const []);
        }
        final exact = candidates.where((s) {
          if (entry.artist == null ||
              artist.isEmpty ||
              wishArtistKey(s.artist).isEmpty) {
            return false;
          }
          if (entry.artist!.trim().toLowerCase() ==
                  (s.artist ?? '').trim().toLowerCase() &&
              entry.title.trim().toLowerCase() ==
                  (s.title ?? '').trim().toLowerCase()) {
            return true;
          }
          final key = dupKeyFor(entry.artist, entry.title);
          return key.isNotEmpty &&
              key.split('|').first.isNotEmpty &&
              key == dupKeyFor(s.artist, s.title);
        }).toList();
        if (exact.isEmpty) {
          return WishResult(entry, WishStatus.ambiguous, candidates);
        }
        final ordered = SongCopies(exact).songs;
        return WishResult(
          entry,
          ordered.any((s) => !s.damaged)
              ? WishStatus.owned
              : WishStatus.damaged,
          ordered,
        );
      }(),
  ];
}

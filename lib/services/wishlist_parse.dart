class WishEntry {
  const WishEntry({
    required this.line,
    required this.title,
    this.artist,
    this.album,
  });

  final String line;
  final String title;
  final String? artist;
  final String? album;
}

String _unquote(String text) {
  final s = text.trim();
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith('“') && s.endsWith('”')))) {
    return s.substring(1, s.length - 1).trim();
  }
  return s;
}

/// A trailing parenthesis is interpreted as an album only when explicitly
/// labelled, so version names such as "(Live)" remain part of the title.
List<WishEntry> parseWishlist(String text) {
  final entries = <WishEntry>[];
  final seen = <String>{};
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    var line = raw.trim();
    line = line.replaceFirst(RegExp(r'^(?:\d+[.)]\s*|[-*•]\s+)'), '').trim();
    if (line.isEmpty) continue;
    String? album;
    final hint = RegExp(
      r'\s*[\[(]\s*album\s*:\s*([^\])]+)[\])]\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (hint != null) {
      album = hint.group(1)!.trim();
      line = line.substring(0, hint.start).trim();
    }
    String? artist;
    String title;
    final by = RegExp(r'\s+by\s+', caseSensitive: false).firstMatch(line);
    final separator = RegExp(r'\s+[-–—]\s+|:\s+|,\s+').firstMatch(line);
    if (by != null) {
      title = _unquote(line.substring(0, by.start));
      artist = _unquote(line.substring(by.end));
    } else if (separator != null) {
      artist = _unquote(line.substring(0, separator.start));
      title = _unquote(line.substring(separator.end));
    } else {
      title = _unquote(line);
    }
    if (title.isEmpty) continue;
    if (artist != null && artist.isEmpty) artist = null;
    final key =
        '${artist?.toLowerCase() ?? ''}\u0000${title.toLowerCase()}\u0000${album?.toLowerCase() ?? ''}';
    if (seen.add(key)) {
      entries.add(
        WishEntry(line: raw.trim(), artist: artist, title: title, album: album),
      );
    }
  }
  return entries;
}

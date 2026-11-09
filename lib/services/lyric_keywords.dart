const _stop = {
  'the', 'and', 'you', 'your', 'for', 'are', 'but', 'not', 'all', 'can', 'her', 'was',
  'one', 'our', 'out', 'has', 'had', 'his', 'how', 'its', 'let', 'may', 'she', 'too',
  'who', 'why', 'with', 'that', 'this', 'they', 'them', 'then', 'than', 'there', 'when',
  'what', 'will', 'would', 'been', 'have', 'from', 'just', 'like', 'into', 'over', 'dont',
  'cant', 'wont', 'ive', 'im', 'ill', 'got', 'get', 'now', 'say', 'said', 'oh',
  'yeah', 'ooh', 'la', 'na', 'gonna', 'wanna', 'cause', 'baby', 'while', 'where', 'only',
  'every', 'ever', 'some', 'more', 'much', 'very', 'does', 'did', 'were', 'which', 'could',
  'should', 'about', 'again', 'still', 'down', 'back', 'way', 'make', 'know', 'take', 'come',
  'see', 'want', 'need', 'feel', 'tell', 'never', 'always', 'own', 'also', 'any', 'off',
};

/// Most frequent meaningful words across [lyrics] (a word counts once per song
/// at most twice, so one repeated chorus does not dominate).
List<MapEntry<String, int>> topKeywords(Iterable<String?> lyrics, {int n = 20}) {
  final counts = <String, int>{};
  final word = RegExp(r"[a-z']+");
  for (final l in lyrics) {
    if (l == null || l.isEmpty) continue;
    final inSong = <String, int>{};
    for (final m in word.allMatches(l.toLowerCase())) {
      final w = m.group(0)!.replaceAll("'", '');
      if (w.length < 3 || _stop.contains(w)) continue;
      inSong[w] = (inSong[w] ?? 0) + 1;
    }
    inSong.forEach((w, c) => counts[w] = (counts[w] ?? 0) + (c > 2 ? 2 : c));
  }
  final out = counts.entries.where((e) => e.value > 1).toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return out.take(n).toList();
}

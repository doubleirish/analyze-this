/// ID3v1 genre names (the standard 80 plus the Winamp extensions).
const id3v1Genres = [
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', 'Hip-Hop', 'Jazz',
  'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B', 'Rap', 'Reggae', 'Rock', 'Techno',
  'Industrial', 'Alternative', 'Ska', 'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno',
  'Ambient', 'Trip-Hop', 'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical', 'Instrumental',
  'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', 'Alternative Rock', 'Bass', 'Soul',
  'Punk', 'Space', 'Meditative', 'Instrumental Pop', 'Instrumental Rock', 'Ethnic', 'Gothic',
  'Darkwave', 'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream',
  'Southern Rock', 'Comedy', 'Cult', 'Gangsta', 'Top 40', 'Christian Rap', 'Pop/Funk', 'Jungle',
  'Native American', 'Cabaret', 'New Wave', 'Psychedelic', 'Rave', 'Showtunes', 'Trailer',
  'Lo-Fi', 'Tribal', 'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll',
  'Hard Rock', 'Folk', 'Folk-Rock', 'National Folk', 'Swing', 'Fast Fusion', 'Bebop', 'Latin',
  'Revival', 'Celtic', 'Bluegrass', 'Avantgarde', 'Gothic Rock', 'Progressive Rock',
  'Psychedelic Rock', 'Symphonic Rock', 'Slow Rock', 'Big Band', 'Chorus', 'Easy Listening',
  'Acoustic', 'Humour', 'Speech', 'Chanson', 'Opera', 'Chamber Music', 'Sonata', 'Symphony',
  'Booty Bass', 'Primus', 'Porn Groove', 'Satire', 'Slow Jam', 'Club', 'Tango', 'Samba',
  'Folklore', 'Ballad', 'Power Ballad', 'Rhythmic Soul', 'Freestyle', 'Duet', 'Punk Rock',
  'Drum Solo', 'A Cappella', 'Euro-House', 'Dance Hall', 'Goa', 'Drum & Bass', 'Club-House',
  'Hardcore', 'Terror', 'Indie', 'BritPop', 'Afro-Punk', 'Polsk Punk', 'Beat',
  'Christian Gangsta Rap', 'Heavy Metal', 'Black Metal', 'Crossover', 'Contemporary Christian',
  'Christian Rock', 'Merengue', 'Salsa', 'Thrash Metal', 'Anime', 'JPop', 'Synthpop',
];

/// Turns ID3 genre codes like "(108)", "(17)Rock" or "17" into names and
/// folds near-duplicate spellings into one name (see [canonicalGenre]).
/// Returns '' when only an unknown code is left.
String cleanGenre(String? raw) {
  final s = _decodeGenre(raw);
  return s.isEmpty ? '' : canonicalGenre(s);
}

const unknownGenre = 'Unknown';

final _lateGenre = RegExp(
    r'(?<![a-z0-9])(country|folk|bluegrass|soul|gospel|reggae|comedy|americana|'
    r'singer[- /]?songwriter|ska|dub|dancehall|spoken word|stand[- ]?up)(?![a-z0-9])',
    caseSensitive: false);

/// Genres a full scan leaves until after the mainstream ones (country, folk,
/// soul, gospel, reggae, comedy and close relatives), matched as whole words
/// so "Neo-Soul" counts but "Dubstep" doesn't.
bool isLateGenre(String genre) => _lateGenre.hasMatch(genre);

/// Genre tags that say nothing about the music (placeholders, labels, artist
/// names, format notes, truncated junk).
const _garbageGenres = {
  'other', 'unknown', 'desconocido', 'genre', 'misc', 'miscellaneous', 's', "'s", 'default',
  'general', 'unclassifiable', 'unclassifiab', 'mst', 'matador', 'primus', 'neily baby',
  "deezer's favorites", '2.7 powerslave (live)', 'porn groove', 'sound clip', 'dolby atmos',
  'top 40', 'slow', 'retro', 'contemporary', 'college', 'general unclassifiab',
  'general unclassifiable', 'genre unknown', 'none', 'n/a', 'undefined', 'blank', 'untitled',
};

/// Spellings folded into one canonical genre (compared case-insensitively,
/// after dropping a leading "General ").
const _genreMerges = <String, List<String>>{
  'Electronic': [
    'electronica', 'electro', 'electronica & dance', 'electronica/dance', 'electronic/dance',
    'techno_electronic_disco', 'rave', 'edm'
  ],
  'Dance': ['club dance', 'club', 'dance music'],
  'Techno': ['euro-techno', 'ambient techno'],
  'Trance': ['tech trance'],
  'Industrial': ['industrial dance'],
  'Downtempo': ['chillout', 'chill out'],
  'Drum & Bass': ['jungle', 'drum and bass', "drum 'n' bass", 'dnb'],
  'Trip-Hop': ['trip hop', 'triphop'],
  'Rock': ['rock/pop', 'rock / pop', 'pop/rock', 'pop / rock', 'slow rock'],
  'Rock & Roll': ["'50s rock 'n' roll", 'rock and roll', "rock 'n' roll", 'rock n roll'],
  'Hard Rock': [],
  'Metal': ['heavy metal', 'british metal'],
  'Alternative Rock': ['alt rock', 'alt-rock'],
  'Alternative': [
    'alternative & punk', 'adult alternative', 'ambient alternative', 'alternative general',
    'alt', 'adult alternative pop/rock'
  ],
  'Folk': [
    'traditional folk', 'modern folk', 'contemporary folk', 'new folk', 'alt-folk', 'folklore'
  ],
  'Folk-Rock': ['folk/rock', 'folk rock'],
  'Folk Pop': ['pop-folk', 'pop folk', 'folk-pop'],
  'Hip-Hop': [
    'hip hop', 'hiphop', 'rap & hip hop', 'rap / hip-hop', 'hip hop/rap', 'rap/hip hop',
    'rap', 'underground rap', 'alternative hip-hop', 'alternative hip hop'
  ],
  'R&B': ['rnb', 'r and b', 'r&b/soul', 'contemporary r&b'],
  'AOR': ['aor'],
  'IDM': ['idm'],
  'Soul': ['blue-eyed soul'],
  'Jazz': ['jazz instrument', 'bop', 'jazz+funk', 'acid jazz', 'pop-jazz'],
  'Vocal Jazz': ['jazz vocals'],
  'Country': ['contemporary country', 'texas country'],
  'Alternative Country': [],
  'Bluegrass': ['newgrass'],
  'Dancehall': ['dance hall'],
  'Soundtrack': ['film soundtrack', 'film score', 'film scores', 'score'],
  'Musical': ['showtunes', 'show tunes'],
  'New Age': ['newage'],
  'Celtic': ['irish celtic'],
  'World': ['worldbeat', 'world beat', 'ethnic fusion', 'indian'],
  'Latin': ['latin music'],
  'Pop': ['pop vocals', 'european pop', 'acoustic pop', 'lilith pop', 'euro pop'],
  'Synthpop': ['synth pop', 'synth-pop'],
  'Britpop': ['brit pop', 'brit-pop'],
  'Punk': ['old school punk'],
  'Post-Punk': ['post punk'],
  'Goth': ['goth rock', 'gothic rock'],
  'Psychedelic Rock': ['psychedelic'],
  'Instrumental': ['guitar instrumental'],
  'Lo-Fi': ['lo-fi/garage'],
  'Spoken Word': ['vocal spoken word'],
  'Progressive Rock': ['prog rock', 'progressive'],
  'Grunge': ['post-grunge'],
};

final Map<String, String> _canonByKey = () {
  final m = <String, String>{};
  _genreMerges.forEach((canon, aliases) {
    m[canon.toLowerCase()] = canon;
    for (final a in aliases) {
      m[a] = canon;
    }
  });
  return m;
}();

/// The one name a genre goes by: spellings differing in case, "General "
/// prefix or punctuation are merged (Electro / Electronica / Electronic →
/// Electronic), and placeholder or junk tags become "Unknown". Names this
/// doesn't know pass through, tidied.
String canonicalGenre(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return '';
  var key = s.toLowerCase();
  if (key.startsWith('general ') && key.length > 8) {
    key = key.substring(8);
    s = s.substring(8);
  }
  if (_garbageGenres.contains(key) || key.length < 2) return unknownGenre;
  if (RegExp(r'^[\d\W_]+$').hasMatch(key)) return unknownGenre;
  final c = _canonByKey[key];
  if (c != null) return c;
  if (s == s.toLowerCase() || s == s.toUpperCase()) {
    s = [for (final w in s.split(' ')) w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()]
        .join(' ');
    final again = _canonByKey[s.toLowerCase()];
    if (again != null) return again;
  }
  return s;
}

String _decodeGenre(String? raw) {
  var s = (raw ?? '').trim();
  if (s.isEmpty) return '';
  final codes = <String>[];
  final group = RegExp(r'^\((\w+)\)\s*');
  for (var m = group.firstMatch(s); m != null; m = group.firstMatch(s)) {
    codes.add(m.group(1)!);
    s = s.substring(m.end);
  }
  if (RegExp(r'^\d+$').hasMatch(s)) {
    codes.add(s);
    s = '';
  }
  // "(4)(5)Foo" keeps the text; a bare "(4)" uses the code's name
  if (s.isNotEmpty) return s.replaceAll('((', '(');
  for (final c in codes) {
    final n = int.tryParse(c);
    if (n != null && n >= 0 && n < id3v1Genres.length) return id3v1Genres[n];
    if (c == 'RX') return 'Remix';
    if (c == 'CR') return 'Cover';
  }
  return '';
}

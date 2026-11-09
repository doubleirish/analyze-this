import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/mix_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/services/mix_icon_spec.dart';

void main() {
  late MusicDb db;

  setUp(() async {
    db = await MusicDb.open(':memory:');
    for (final s in ['a', 'b', 'c']) {
      await db.upsertSong(Song(path: s, title: s, duration: 200, medianBpm: 120, avgBpm: 120));
    }
  });
  tearDown(() => db.close());

  test('icon, pin, archive and tags persist and show in summaries', () async {
    final id = await db.saveMix('Run', ['a', 'b']);
    await db.setMixIcon(id, const MixIconSpec('run', 0xFF112233));
    await db.setMixesPinned([id], true);
    await db.tagMixes([id], 'cardio');
    var m = (await db.mixSummaries()).single;
    expect(m.icon, isNotNull);
    expect(m.pinned, isTrue);
    expect(m.tags, ['cardio']);
    expect((await db.mixIcon(id))!.color, 0xFF112233);

    await db.tagMixes([id], 'cardio', remove: true);
    await db.setMixesArchived([id], true);
    m = (await db.mixSummaries()).single;
    expect(m.tags, isEmpty);
    expect(m.archived, isTrue);
  });

  test('delete then restore brings back songs and tags; duplicate copies icon and tags', () async {
    final id = await db.saveMix('Run', ['a', 'b']);
    await db.setMixIcon(id, const MixIconSpec('run', 0xFF112233));
    await db.tagMixes([id], 'cardio');
    final dup = await db.duplicateMix(id, 'Run copy');
    final copy = (await db.mixSummaries()).firstWhere((m) => m.id == dup);
    expect(copy.tags, ['cardio']);
    expect(copy.icon, isNotNull);

    final gone = await db.deleteMixes([id, dup]);
    expect(gone.count, 2);
    expect(await db.mixSummaries(), isEmpty);
    await db.restoreMixes(gone);
    final back = await db.mixSummaries();
    expect(back.length, 2);
    expect(back.every((m) => m.songCount == 2 && m.tags.contains('cardio')), isTrue);
  });

  test('restore renames when the name was reused', () async {
    final id = await db.saveMix('Run', ['a']);
    final gone = await db.deleteMixes([id]);
    await db.saveMix('Run', ['b']);
    await db.restoreMixes(gone);
    expect((await db.mixSummaries()).map((m) => m.name).toSet(), {'Run', 'Run (restored)'});
  });

  test('arrangeMixes filters and puts pinned first', () async {
    final x = await db.saveMix('Alpha', ['a']);
    await db.saveMix('Beta', ['b']);
    final z = await db.saveMix('Gamma', ['c']);
    await db.setMixesPinned([z], true);
    await db.tagMixes([x], 'warm');
    await db.setMixesArchived([x], true);
    final all = await db.mixSummaries();

    expect(arrangeMixes(all, const MixFilter(), MixSort.name).map((m) => m.name), ['Gamma', 'Beta']);
    expect(arrangeMixes(all, const MixFilter(archived: true), MixSort.name).map((m) => m.name), ['Alpha']);
    expect(arrangeMixes(all, const MixFilter(query: 'warm', archived: true), MixSort.name), hasLength(1));
    expect(arrangeMixes(all, const MixFilter(tag: 'warm'), MixSort.name), isEmpty);
    expect(arrangeMixes(all, const MixFilter(pinnedOnly: true), MixSort.name).single.name, 'Gamma');
  });
}

import 'dart:io';

import 'package:analyze_this/services/db.dart';
import 'package:analyze_this/services/phone_link.dart';
import 'package:analyze_this/services/phone_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

const _a = 'C:\\m\\a.mp3';

void main() {
  late MusicDb db;
  late Directory tmp;

  setUp(() async {
    db = await MusicDb.open(':memory:');
    await db.upsertSong(Song(path: _a, title: 'Song A', artist: 'Band', duration: 200));
    tmp = await Directory.systemTemp.createTemp('wifi_sync_');
  });
  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('PhoneLink.syncJournal imports the phone journal, acks, and the phone trims it', () async {
    final journal = PlayJournal(File(p.join(tmp.path, 'journal.jsonl')));
    await journal.append(JournalEntry(
        type: JournalEntry.play, at: 1000000, device: 'ph1', origPath: _a, listened: 150, done: true));
    await journal.append(JournalEntry(
        type: JournalEntry.rate, at: 1000500, device: 'ph1', origPath: _a, rating: 4, fav: true));
    await journal.append(JournalEntry(
        type: JournalEntry.play, at: 1001000, device: 'ph1', origPath: 'C:\\gone.mp3', listened: 10, done: false));

    final phone = PushReceiver(
      importer: MixtapeImporter(Directory(p.join(tmp.path, 'music'))),
      staging: Directory(p.join(tmp.path, 'staging')),
      deviceId: 'ph1',
      isTrusted: (t) => t == 'tok',
      journal: journal.since,
      ackJournal: journal.trimTo,
    );
    await phone.start(port: 0);
    addTearDown(phone.stop);

    final synced = <PhoneSyncResult>[];
    final link = PhoneLink(db)..onSynced = synced.add;
    final paired = PairedPhone(id: 'ph1', name: 'Phone', token: 'tok', host: '127.0.0.1', port: phone.port);

    final r = (await link.syncJournal(paired))!;
    expect(r.plays, 1);
    expect(r.ratings, 1);
    expect(r.unmatched, 1);
    expect(r.ackSeq, 3);
    expect(await db.playTimes([_a]), {_a: [1000000]});
    expect((await db.song(_a))!.rating, 4);
    expect(await journal.since(0), isEmpty);
    expect(await link.sync.cursor('ph1'), 3);
    expect(synced.single.plays, 1);

    await journal.append(JournalEntry(
        type: JournalEntry.play, at: 2000000, device: 'ph1', origPath: _a, listened: 150, done: true));
    final again = (await link.syncJournal(paired))!;
    expect(again.plays, 1);
    expect(again.ackSeq, 4);
    expect(await journal.since(0), isEmpty);

    final none = (await link.syncJournal(paired))!;
    expect(none.plays + none.ratings + none.unmatched, 0);
  });

  test('pull: the phone posts its journal to PhoneLink\'s pull server', () async {
    final link = PhoneLink(db);
    final l = await link.servePull(tmp, 'Mix');
    addTearDown(link.stopPull);
    final c = PullClient(Uri.parse('http://127.0.0.1:${l.port}'), l.token);
    final ack = await c.sendJournal([
      JournalEntry(seq: 7, type: JournalEntry.play, at: 1000000, device: 'ph2', origPath: _a, listened: 150, done: true),
    ]);
    expect(ack, 7);
    expect(await db.playTimes([_a]), {_a: [1000000]});
    expect(await link.sync.cursor('ph2'), 7);
  });

  test('journal sync sends album catalogue, skips unchanged, and updates removals', () async {
    await db.upsertSong(Song(path: _a, album: 'Album', artist: 'Band', trackNo: 1, trackTotal: 2));
    final received = <AlbumCatalog>[];
    final receiver = PushReceiver(
      importer: MixtapeImporter(Directory(p.join(tmp.path, 'music'))),
      staging: Directory(p.join(tmp.path, 'staging')),
      isTrusted: (t) => t == 'tok',
      onCatalog: (c) async => received.add(c),
    );
    await receiver.start(port: 0);
    addTearDown(receiver.stop);
    final link = PhoneLink(db);
    final phone = PairedPhone(id: 'ph1', name: 'Phone', token: 'tok', host: '127.0.0.1', port: receiver.port);
    await link.syncJournal(phone);
    expect(received.single.albums.single.incomplete, isTrue);
    await link.syncJournal(phone);
    expect(received.length, 1);
    await db.upsertSong(Song(path: r'E:\archive\b.mp3', album: 'Album', artist: 'Band',
        trackNo: 2, trackTotal: 2));
    await link.syncJournal(phone);
    expect(received.length, 2);
    expect(received.last.albums.single.incomplete, isFalse);
    await link.syncCatalog(phone, force: true);
    expect(received.length, 3);
    // Removing album tags must replace the list, not merge stale owned entries.
    await db.upsertSong(Song(path: _a));
    await db.upsertSong(Song(path: r'E:\archive\b.mp3'));
    await link.syncJournal(phone);
    expect(received.last.albums, isEmpty);
  });

  test('failed catalogue sends are reported separately from journal and retried', () async {
    var fail = true;
    var attempts = 0;
    final receiver = PushReceiver(
      importer: MixtapeImporter(Directory(p.join(tmp.path, 'music'))),
      staging: Directory(p.join(tmp.path, 'staging')),
      isTrusted: (t) => t == 'tok',
      onCatalog: (_) async {
        attempts++;
        if (fail) throw const FileSystemException('disk full');
      },
    );
    await receiver.start(port: 0);
    addTearDown(receiver.stop);
    final link = PhoneLink(db);
    final phone = PairedPhone(id: 'ph1', name: 'Phone', token: 'tok', host: '127.0.0.1', port: receiver.port);
    expect(await link.syncJournal(phone), isNotNull);
    expect(link.lastCatalogSyncNote, contains('Could not sync'));
    expect(await db.setting('album_catalog_sent:ph1'), isNull);
    fail = false;
    await link.syncJournal(phone);
    expect(attempts, 2);
    expect(link.lastCatalogSyncNote, contains('synced'));
    expect(await db.setting('album_catalog_sent:ph1'), isNotNull);
  });
}

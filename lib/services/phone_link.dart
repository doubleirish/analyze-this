import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

import 'album_catalog.dart';
import 'db.dart';
import 'phone_sync.dart';

/// A phone this PC paired with (beats-me issued [token] to us).
class PairedPhone {
  PairedPhone({required this.id, required this.name, required this.token, this.host, this.port});
  final String id, name, token;
  String? host;
  int? port;

  Uri? get uri => host == null ? null : Uri.parse('http://$host:${port ?? pushPort}');

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'token': token, 'host': host, 'port': port};
  static PairedPhone fromJson(Map<String, dynamic> j) => PairedPhone(
      id: '${j['id']}',
      name: '${j['name']}',
      token: '${j['token']}',
      host: j['host'] as String?,
      port: (j['port'] as num?)?.toInt());
}

/// A phone the user can pick in the Send dialog: found on the network now,
/// paired earlier, or both.
class PhoneChoice {
  PhoneChoice(this.id, this.name, {this.found, this.paired});
  final String id, name;
  final DiscoveredPhone? found;
  final PairedPhone? paired;

  bool get online => found != null;
  Uri? get uri => found?.uri ?? paired?.uri;
}

/// What the phone reported after downloading a mixtape from the pull server.
class PullReport {
  PullReport(this.id, this.report, this.at);
  final String id;
  final Map<String, dynamic> report;
  final DateTime at;
}

/// PC-side state for Wi-Fi transfers that outlives the Send dialog:
/// this PC's identity, paired phones, discovery and the pull server.
class PhoneLink extends ChangeNotifier {
  PhoneLink(this.db, {this.syncFactory});
  final MusicDb db;

  /// Makes the [PhoneSync] used for journal imports (AppState passes one
  /// that reacts to new plays); a plain one when null.
  final PhoneSync Function()? syncFactory;
  PhoneSync get sync => syncFactory?.call() ?? PhoneSync(db);

  /// Called after every journal sync (Wi-Fi push or pull), even empty ones.
  void Function(PhoneSyncResult result)? onSynced;

  /// The last journal sync's result, for the UI.
  PhoneSyncResult? lastSync;
  String? lastCatalogSyncNote;

  String pcId = '';
  String get pcName => Platform.localHostname;
  final List<PairedPhone> paired = [];
  List<DiscoveredPhone> found = [];
  bool searching = false;

  PullServer? _pull;
  PullServer? get pull => _pull;
  String? pullMixName;
  PullReport? lastPullReport;

  Future<void> load() async {
    var id = await db.setting('pc_device_id');
    if (id == null) {
      id = newMixtapeId();
      await db.setSetting('pc_device_id', id);
    }
    pcId = id;
    paired.clear();
    try {
      final list = jsonDecode(await db.setting('paired_phones') ?? '[]') as List;
      paired.addAll([for (final j in list) PairedPhone.fromJson((j as Map).cast<String, dynamic>())]);
    } catch (_) {}
  }

  Future<void> _savePaired() =>
      db.setSetting('paired_phones', jsonEncode([for (final p in paired) p.toJson()]));

  PairedPhone? pairedById(String id) => paired.where((p) => p.id == id).firstOrNull;

  /// Discovered and paired phones merged by id; online ones first.
  List<PhoneChoice> get choices {
    final out = <String, PhoneChoice>{};
    for (final f in found) {
      out[f.id] = PhoneChoice(f.id, f.name, found: f, paired: pairedById(f.id));
    }
    for (final p in paired) {
      out.putIfAbsent(p.id, () => PhoneChoice(p.id, p.name, paired: p));
    }
    return out.values.toList()..sort((a, b) => (a.online == b.online ? 0 : (a.online ? -1 : 1)));
  }

  /// Looks for beats-me phones that are receiving on this network (beats-me
  /// open with auto-receive on, or its Import screen open).
  Future<List<DiscoveredPhone>> discover({List<String> extraHosts = const []}) async {
    searching = true;
    notifyListeners();
    try {
      found = await discoverPhones(extraHosts: extraHosts);
      var changed = false;
      for (final f in found) {
        final p = pairedById(f.id);
        if (p != null && (p.host != f.host || p.port != f.port)) {
          p.host = f.host;
          p.port = f.port;
          changed = true;
        }
      }
      if (changed) await _savePaired();
      return found;
    } catch (_) {
      found = [];
      return found;
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  /// One-time pairing: the phone shows [code] and asks the user to allow
  /// this PC. Throws [TransferException] when declined or unreachable.
  Future<PairedPhone> pair(Uri phone, String code) async {
    final r = await PushSender.pair(phone, pcName: pcName, pcId: pcId, code: code);
    paired.removeWhere((p) => p.id == r.id);
    final p = PairedPhone(id: r.id.isEmpty ? phone.host : r.id, name: r.name, token: r.token,
        host: phone.host, port: phone.port);
    paired.add(p);
    await db.setSetting('album_catalog_sent:${p.id}', '');
    await _savePaired();
    notifyListeners();
    return p;
  }

  Future<void> forget(String id) async {
    paired.removeWhere((p) => p.id == id);
    await _savePaired();
    await db.setSetting('album_catalog_sent:$id', '');
    notifyListeners();
  }

  /// Starts (or keeps) the pull server for packages under `<root>/pull`.
  /// It keeps running after the Send dialog closes until [stopPull].
  Future<PullLink> servePull(Directory root, String mixName) async {
    if (_pull == null || _pull!.root.path != root.path) {
      await _pull?.stop();
      final server = PullServer(
          root: root,
          name: pcName,
          onPhoneDone: (id, report) {
            lastPullReport = PullReport(id, report, DateTime.now());
            notifyListeners();
          },
          onJournal: (entries) async => (await _importEntries(entries, '')).ackSeq);
      await server.start();
      _pull = server;
    }
    pullMixName = mixName;
    lastPullReport = null;
    notifyListeners();
    return _pull!.link();
  }

  Future<void> stopPull() async {
    await _pull?.stop();
    _pull = null;
    pullMixName = null;
    notifyListeners();
  }

  /// Pulls the play/rating journal from [phone] over Wi-Fi (entries after
  /// this PC's cursor), imports it and lets the phone trim what was stored.
  /// Returns null when the phone has no address. Throws [TransferException].
  Future<PhoneSyncResult?> syncJournal(PairedPhone phone, {Uri? via}) async {
    final uri = via ?? phone.uri;
    if (uri == null) return null;
    final sender = PushSender(uri, phone.token);
    final entries = await sender.journal(since: await sync.cursor(phone.id));
    final r = await _importEntries(entries, phone.id);
    if (entries.isNotEmpty && r.ackSeq > 0) await sender.ackJournal(r.ackSeq);
    lastCatalogSyncNote = null;
    try {
      final catalog = await syncCatalog(phone, via: uri);
      lastCatalogSyncNote = catalog == null
          ? 'Album list unchanged.'
          : 'Album list synced: ${catalog.albums.length} albums.';
    } catch (e) {
      lastCatalogSyncNote = 'Could not sync the album list: $e';
      debugPrint(lastCatalogSyncNote);
    }
    notifyListeners();
    return r;
  }

  /// Null means unchanged. Manual sends force a fresh snapshot, also repairing
  /// a phone whose app data was cleared after the previous successful sync.
  Future<AlbumCatalog?> syncCatalog(PairedPhone phone, {Uri? via, bool force = false}) async {
    final uri = via ?? phone.uri;
    if (uri == null) throw TransferException('No address for ${phone.name}. Search for the phone again.');
    final sender = PushSender(uri, phone.token);
    if (!(await sender.hello()).catalog) {
      throw TransferException('Update beats-me on the phone to receive the album list.');
    }
    final catalog = buildAlbumCatalog(await db.albumCatalogSongs());
    final key = 'album_catalog_sent:${phone.id}';
    final hash = catalog.fingerprint;
    if (!force && await db.setting(key) == hash) return null;
    await sender.sendCatalog(catalog);
    await db.setSetting(key, hash);
    return catalog;
  }

  /// Imports [entries] per their `device` ([fallbackDevice] when empty).
  /// The ack never exceeds the highest seq received.
  Future<PhoneSyncResult> _importEntries(List<JournalEntry> entries, String fallbackDevice) async {
    final byDevice = <String, List<JournalEntry>>{};
    var maxSeq = 0;
    for (final e in entries) {
      final d = e.device.isNotEmpty ? e.device : (fallbackDevice.isNotEmpty ? fallbackDevice : 'unknown');
      (byDevice[d] ??= []).add(e);
      if (e.seq > maxSeq) maxSeq = e.seq;
    }
    var total = const PhoneSyncResult();
    final ps = sync;
    for (final MapEntry(:key, :value) in byDevice.entries) {
      total += await ps.importJournal(key, value);
    }
    final r = PhoneSyncResult(
        plays: total.plays,
        ratings: total.ratings,
        unmatched: total.unmatched,
        ackSeq: total.ackSeq < maxSeq ? total.ackSeq : maxSeq,
        playedPaths: total.playedPaths);
    lastSync = r;
    onSynced?.call(r);
    notifyListeners();
    return r;
  }
}

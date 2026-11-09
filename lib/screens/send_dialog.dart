import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_core/shared_core.dart';

import '../services/app_state.dart';
import '../services/keep_awake.dart';
import '../services/mixtape_export.dart';
import '../services/phone_link.dart';
import '../services/usb_sync.dart';

enum _Level { ok, info, warn, error }

class _Check {
  const _Check(this.level, this.text);
  final _Level level;
  final String text;
}

class _Method {
  const _Method(this.id, this.icon, this.title, this.subtitle);
  final String id;
  final IconData icon;
  final String title, subtitle;
}

/// What a paired phone needs to be reachable over Wi-Fi.
const _openPhoneHint = 'Unlock the phone and open beats-me (or beats-me › Import if “Receive mixes '
    'from PC while beats-me is open” is off), then press Search.';

const _primary = [
  _Method(Transport.push, Icons.wifi, 'Wi-Fi to phone',
      'Open beats-me on the phone (Import the first time), same Wi-Fi as this PC.'),
  _Method(Transport.usb, Icons.usb, 'USB cable',
      'Most dependable. Needs USB debugging switched on once.'),
  _Method(Transport.pull, Icons.qr_code_2, 'Phone downloads (QR code)',
      'Scan a code in beats-me when the phone can’t be found.'),
  _Method(Transport.zip, Icons.archive_outlined, '.beatsmix file',
      'Share by Quick Share, email, cloud or cable; tap it on the phone.'),
];
const _more = [
  _Method(Transport.folder, Icons.folder_outlined, 'Export folder',
      'Write a folder you copy to the phone yourself.'),
  _Method(Transport.syncdir, Icons.sync, 'Sync folder',
      'Folder synced to the phone (Syncthing, Drive…); beats-me watches it.'),
];

/// Sends the current mix (songs + metadata) to beats-me. It remembers the
/// method and phone per mix, checks everything before sending, and explains
/// problems in plain language.
class SendToPhoneDialog extends StatefulWidget {
  const SendToPhoneDialog({super.key, required this.state, this.albumsOnly = false});
  final AppState state;
  final bool albumsOnly;

  @override
  State<SendToPhoneDialog> createState() => _SendToPhoneDialogState();
}

class _SendToPhoneDialogState extends State<SendToPhoneDialog> {
  AppState get s => widget.state;
  PhoneLink get link => s.phones;
  late final MixtapeExport _export = MixtapeExport(s);

  final _ffmpeg = TextEditingController();
  final _adbPath = TextEditingController();
  final _manualAddr = TextEditingController();
  final _manualCode = TextEditingController();

  String _method = Transport.push;
  String? _phoneId;
  String? _serial;
  String? _folder;
  String _preset = TranscodePreset.autoId;
  bool _showMore = false;

  // Facts about the mix's files.
  int _bytes = 0;
  final List<String> _missing = [];
  final List<String> _unplayable = [];

  String? _adb;
  List<AdbDevice> _usb = [];
  bool _usbChecked = false;

  List<_Check> _checks = [];
  bool _checking = false;
  int _gen = 0;
  Timer? _debounce;

  bool _busy = false;
  bool _cancel = false;
  double? _progress;
  String _status = '';
  List<String> _result = [];
  bool _failed = false;
  PullLink? _pullLink;
  String? _savedFile;
  String? _pairCode;

  @override
  void initState() {
    super.initState();
    link.addListener(_onLink);
    _init();
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    _debounce?.cancel();
    _ffmpeg.dispose();
    _adbPath.dispose();
    _manualAddr.dispose();
    _manualCode.dispose();
    super.dispose();
  }

  void _onLink() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    for (final song in s.mixer.mix) {
      if (widget.albumsOnly) break;
      final f = File(song.path);
      if (!f.existsSync()) {
        _missing.add(p.basename(song.path));
        continue;
      }
      _bytes += f.lengthSync();
      if (!androidPlayable(song.path)) _unplayable.add(p.basename(song.path));
    }
    final db = s.db;
    Map<String, dynamic> pref = {};
    for (final k in [
      if (!widget.albumsOnly) 'send_pref:${s.mixer.mixKey}',
      'send_pref:last',
    ]) {
      final raw = await db.setting(k);
      if (raw != null) {
        try {
          pref = (jsonDecode(raw) as Map).cast<String, dynamic>();
          break;
        } catch (_) {}
      }
    }
    _method = Transport.all.contains(pref['method']) ? pref['method'] as String : Transport.push;
    if (widget.albumsOnly && _method != Transport.push && _method != Transport.usb) _method = Transport.push;
    _phoneId = pref['phone'] as String?;
    _serial = pref['serial'] as String?;
    _folder = pref['folder'] as String? ?? await db.setting('mixtape_folder');
    _preset = pref['preset'] as String? ?? TranscodePreset.autoId;
    _showMore = _more.any((m) => m.id == _method);
    if (!widget.albumsOnly) _ffmpeg.text = await _export.detectFfmpeg() ?? '';
    _adbPath.text = await db.setting('adb_path') ?? '';
    if (mounted) setState(() {});
    if (_method == Transport.push) unawaited(_discover());
    _recheck();
  }

  Future<void> _savePrefs() async {
    final j = jsonEncode({
      'method': _method,
      'phone': _phoneId,
      'serial': _serial,
      'folder': _folder,
      'preset': _preset,
    });
    if (!widget.albumsOnly) await s.db.setSetting('send_pref:${s.mixer.mixKey}', j);
    await s.db.setSetting('send_pref:last', j);
    if (_folder != null) await s.db.setSetting('mixtape_folder', _folder!);
  }

  // ---------------------------------------------------------------- choices

  Future<void> _discover() async {
    final manual = _manualHost;
    await link.discover(extraHosts: [?manual]);
    if (!mounted) return;
    final choices = link.choices;
    if (_phoneId == null || !choices.any((c) => c.id == _phoneId)) {
      _phoneId = choices.where((c) => c.online).firstOrNull?.id ?? choices.firstOrNull?.id;
    }
    setState(() {});
    _recheck();
  }

  String? get _manualHost {
    final a = _manualAddr.text.trim();
    return a.isEmpty ? null : a.split(':').first;
  }

  Uri? get _manualUri {
    final a = _manualAddr.text.trim();
    if (a.isEmpty) return null;
    return Uri.tryParse(a.contains(':') ? 'http://$a' : 'http://$a:$pushPort');
  }

  PhoneChoice? get _phone => link.choices.where((c) => c.id == _phoneId).firstOrNull;

  Future<void> _loadUsb() async {
    final adb = await UsbTransport.findAdb([if (_adbPath.text.trim().isNotEmpty) _adbPath.text.trim()]);
    var devices = <AdbDevice>[];
    if (adb != null) {
      try {
        devices = await UsbTransport(adb).devices();
      } catch (_) {}
    }
    _adb = adb;
    _usb = devices;
    _usbChecked = true;
    if (_serial == null || !devices.any((d) => d.serial == _serial)) {
      _serial = devices.where((d) => d.ready).firstOrNull?.serial ?? devices.firstOrNull?.serial;
    }
  }

  void _pick(String method) {
    if (_busy) return;
    setState(() {
      _method = method;
      _result = [];
      _status = '';
      _failed = false;
    });
    if (method == Transport.push && link.found.isEmpty && !link.searching) unawaited(_discover());
    _recheck();
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Folder to export into');
    if (dir == null) return;
    setState(() => _folder = dir);
    _recheck();
  }

  // -------------------------------------------------------------- preflight

  void _recheck() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _preflight);
  }

  String get _ffmpegPath => _ffmpeg.text.trim();

  Future<void> _preflight() async {
    final gen = ++_gen;
    if (mounted) setState(() => _checking = true);
    final out = <_Check>[];
    void add(_Level l, String t) => out.add(_Check(l, t));

    int? estimate;
    if (!widget.albumsOnly) {
      if (s.mixer.mix.isEmpty) add(_Level.error, 'The mix is empty.');
      if (_missing.isNotEmpty) {
        add(_Level.error,
            '${_missing.length} song file(s) are missing on this PC: ${_missing.take(3).join(', ')}'
            '${_missing.length > 3 ? '…' : ''}. Remove them from the mix or rescan.');
      }
      final damaged = s.mixer.damagedIndexes;
      if (damaged.isNotEmpty) {
        final eg = damaged.take(2).map((i) => s.mixer.mix[i].title ?? p.basename(s.mixer.mix[i].path)).join(', ');
        add(_Level.warn,
            '${damaged.length} song(s) have damaged audio ($eg) and may skip or stop on the phone. '
            'Close this and use “Replace all” above the mix to swap in similar songs.');
      }
      final explicit = s.mixer.explicitInMix;
      if (explicit.isNotEmpty && s.mixer.cleanClass) {
        add(_Level.warn,
            'Clean class is on but ${explicit.length} song(s) are explicit: '
            '${explicit.take(3).map((m) => m.display).join(', ')}${explicit.length > 3 ? '…' : ''}.');
      }
      final hasFfmpeg = _ffmpegPath.isNotEmpty;
      final converting = _preset != 'copy' && _preset != TranscodePreset.autoId;
      if (converting && !hasFfmpeg) {
        add(_Level.error, 'Converting needs ffmpeg. Set its path under Advanced, or choose Auto.');
      } else if (_unplayable.isNotEmpty) {
        final eg = _unplayable.take(2).join(', ');
        if (_preset == TranscodePreset.autoId && hasFfmpeg) {
          add(_Level.ok, '${_unplayable.length} song(s) Android can’t play ($eg) will be converted to AAC.');
        } else if (!converting) {
          add(_Level.warn,
              '${_unplayable.length} song(s) won’t play on Android ($eg). '
              '${hasFfmpeg ? 'Choose Auto under Advanced to convert them.' : 'Install ffmpeg (or set its path under Advanced) so Auto can convert them.'}');
        }
      }
      estimate = converting ? null : _bytes;
      add(_Level.info, '${s.mixer.mix.length} songs, about ${formatBytes(_bytes)}'
          '${converting ? ' before converting' : ''}.');
    } else {
      add(_Level.info, 'Metadata only: every album in the database, with tag-based track counts. No audio files.');
    }

    try {
      switch (_method) {
        case Transport.push:
          await _checkPush(add, estimate);
        case Transport.usb:
          await _checkUsb(add, estimate);
        case Transport.pull:
          final ips = await lanAddresses();
          if (ips.isEmpty) {
            add(_Level.error, 'This PC isn’t connected to a network.');
          } else {
            add(_Level.ok, 'The phone will connect to ${ips.first}. It must be on the same Wi-Fi.');
            add(_Level.info, 'If the phone can’t connect, allow analyze-this through Windows Firewall '
                '(Private networks) when Windows asks, or under Settings › Firewall › Allow an app.');
          }
        case Transport.zip:
          add(_Level.info, 'You’ll choose where to save the .beatsmix file.');
        default:
          if (_folder == null) {
            add(_Level.error, 'Choose a folder.');
          } else if (!Directory(_folder!).existsSync()) {
            add(_Level.error, 'The folder $_folder no longer exists (drive unplugged?).');
          } else {
            add(_Level.ok, 'Writes into $_folder');
          }
      }
    } catch (e) {
      add(_Level.error, '$e');
    }
    if (gen != _gen || !mounted) return;
    setState(() {
      _checks = out;
      _checking = false;
    });
  }

  Future<void> _checkPush(void Function(_Level, String) add, int? estimate) async {
    final manual = _manualUri;
    if (manual != null) {
      add(_Level.info, 'Using the address entered under Advanced: ${manual.authority}.');
      return;
    }
    final ph = _phone;
    if (ph == null) {
      add(_Level.error, link.searching
          ? 'Looking for phones…'
          : 'No phone found. Unlock the phone and open beats-me (the first time, open beats-me › Import), '
              'make sure it’s on the same Wi-Fi as this PC (not a guest network), then press Search again. '
              'If it still isn’t found, try USB or the QR code.');
      return;
    }
    if (ph.paired == null) {
      add(_Level.info, 'First send to ${ph.name}: open beats-me › Import on the phone and tap Allow there once.');
      return;
    }
    final uri = ph.uri;
    if (uri == null) {
      add(_Level.error, '${ph.name} wasn’t found. $_openPhoneHint');
      return;
    }
    final mine = await lanAddresses();
    if (mine.isNotEmpty && !sameSubnet(uri.host, mine)) {
      add(_Level.warn, '${ph.name} (${uri.host}) seems to be on a different network from this PC.');
    }
    try {
      final hello = await PushSender(uri, ph.paired!.token).hello();
      final free = hello.freeBytes;
      add(_Level.ok, '${hello.name} is ready${free == null ? '' : ' (${formatBytes(free)} free)'}.');
      if (free != null && estimate != null && free < estimate * 1.05) {
        add(_Level.error, 'Not enough space on the phone: needs about ${formatBytes(estimate)}.');
      }
    } on TransferException catch (e) {
      if (e.kind == TransferError.auth) {
        add(_Level.info, '${ph.name} no longer trusts this PC; open beats-me › Import on the phone to Allow it again.');
      } else {
        add(ph.online ? _Level.error : _Level.warn,
            ph.online ? e.message : '${ph.name} isn’t answering. $_openPhoneHint');
      }
    }
  }

  Future<void> _checkUsb(void Function(_Level, String) add, int? estimate) async {
    await _loadUsb();
    if (_adb == null) {
      add(_Level.error, 'adb (Android platform-tools) wasn’t found. Install it from '
          'developer.android.com/tools/releases/platform-tools and set its path under Advanced.');
      return;
    }
    if (_usb.isEmpty) {
      add(_Level.error, 'No phone on USB. Plug it in, then on the phone: Settings › About phone › tap '
          'Build number 7 times, and turn on Developer options › USB debugging.');
      return;
    }
    final d = _usb.where((d) => d.serial == _serial).firstOrNull ?? _usb.first;
    if (!d.ready) {
      add(_Level.error, '${d.label}: ${d.advice}');
      return;
    }
    final free = await UsbTransport(_adb!).freeBytes(d.serial);
    add(_Level.ok, '${d.label} connected${free == null ? '' : ' (${formatBytes(free)} free)'}.');
    if (free != null && estimate != null && free < estimate * 1.05) {
      add(_Level.error, 'Not enough space on the phone: needs about ${formatBytes(estimate)}.');
    }
  }

  bool get _blocked => _checking || _checks.any((c) => c.level == _Level.error);

  // ------------------------------------------------------------------- send

  void _onProgress(int done, int total, String what, String verb) {
    if (!mounted) return;
    setState(() {
      _progress = total == 0 ? null : done / total;
      _status = what == 'done' ? 'Finishing…' : '$verb $what';
    });
  }

  Future<void> _run() async {
    if (widget.albumsOnly) return _runCatalog();
    setState(() {
      _busy = true;
      _cancel = false;
      _failed = false;
      _progress = null;
      _result = [];
      _status = 'Reading songs…';
      _pullLink = null;
      _savedFile = null;
    });
    try {
      final ff = _ffmpegPath;
      if (ff.isNotEmpty) await s.db.setSetting('ffmpeg_path', ff);
      if (_adbPath.text.trim().isNotEmpty) await s.db.setSetting('adb_path', _adbPath.text.trim());
      await _savePrefs();
      final writer = PackageWriter(ffmpegPath: ff.isEmpty ? null : ff);
      final lines = await KeepAwake.during(() async {
        final sources = await _export.sources();
        final cache = await MixtapeExport.cacheDir();
        return switch (_method) {
          Transport.push => _toPhone(writer, sources, cache),
          Transport.usb => _toUsb(writer, sources, cache),
          Transport.pull => _servePull(writer, sources, cache),
          Transport.zip => _toZip(writer, sources, cache),
          _ => _toFolder(writer, sources),
        };
      });
      if (mounted) {
        setState(() => _result = [
              ...lines,
              for (final w in writer.warnings) '⚠ $w',
            ]);
      }
    } on TransferException catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _result = [e.kind == TransferError.cancelled ? 'Cancelled.' : e.message];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _result = ['$e'];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
          _pairCode = null;
        });
      }
    }
  }

  String get _name => s.mixer.mixName.trim().isEmpty ? 'New mix' : s.mixer.mixName.trim();
  bool _cancelled() => _cancel;

  Future<MixIconSpec?> _icon() async {
    final id = s.mixer.mixDbId;
    return id == null ? null : s.db.mixIcon(id);
  }

  Future<MixtapeManifest> _write(
      PackageWriter w, String label, List<MixtapeSource> src, Directory out) async {
    final m = await w.write(
        id: s.mixer.mixKey,
        name: _name,
        sourceName: link.pcName,
        transport: label,
        sources: src,
        out: out,
        transcodeId: _preset == 'copy' ? null : _preset,
        programName: s.mixer.program.name,
        icon: await _icon(),
        onProgress: (d, t, what) => _onProgress(d, t, what, 'Preparing'),
        cancelled: _cancelled);
    await MixtapeExport.recordSent(s.db, m);
    return m;
  }

  Future<PairedPhone> _pairWith(Uri uri) async {
    final code = newPairingCode();
    setState(() {
      _pairCode = code;
      _status = 'Look at the phone and tap Allow';
    });
    try {
      return await link.pair(uri, code);
    } finally {
      if (mounted) setState(() => _pairCode = null);
    }
  }

  Future<List<String>> _toPhone(PackageWriter w, List<MixtapeSource> src, Directory cache) async {
    final pkg = labelDir(cache, Transport.push, s.mixer.mixKey);
    await _write(w, Transport.push, src, pkg);

    final connection = await _connectPhone();
    final sender = connection.sender;
    final phoneName = connection.name;
    final syncWith = connection.paired;
    final r = await sender.send(pkg,
        onProgress: (d, t, what) => _onProgress(d, t, what, 'Sending'), cancelled: _cancelled);
    final synced = syncWith == null ? null : await _syncJournal(syncWith, sender.base);
    return [
      'Sent to $phoneName: ${r.sent} file(s), ${formatBytes(r.bytes)}; '
          '${r.skipped} song(s) were already on the phone.',
      'The phone now has all ${src.length} songs in "$_name".',
      ...r.errors.map((e) => '✗ $e'),
      ?synced,
    ];
  }

  Future<({PushSender sender, String name, PairedPhone? paired})> _connectPhone({bool pairedOnly = false}) async {
    late PushSender sender;
    late String phoneName;
    PairedPhone? syncWith;
    final manual = _manualUri;
    if (!pairedOnly && manual != null && _manualCode.text.trim().isNotEmpty) {
      sender = PushSender(manual, _manualCode.text.trim());
      phoneName = manual.host;
    } else {
      var ph = _phone;
      final uri = manual ?? ph?.uri;
      if (uri == null) throw TransferException('No phone selected.');
      var paired = manual == null ? ph?.paired : null;
      paired ??= await _pairWith(uri);
      _phoneId = paired.id;
      await _savePrefs();
      sender = PushSender(paired.uri ?? uri, paired.token);
      phoneName = paired.name;
      try {
        await sender.hello();
      } on TransferException catch (e) {
        if (e.kind == TransferError.auth) {
          paired = await _pairWith(uri);
          sender = PushSender(paired.uri ?? uri, paired.token);
        } else if (e.kind == TransferError.unreachable || e.kind == TransferError.refused) {
          setState(() => _status = 'Looking for ${paired!.name} again…');
          await link.discover();
          ph = _phone;
          if (ph?.found == null) rethrow;
          sender = PushSender(ph!.found!.uri, paired.token);
        } else {
          rethrow;
        }
      }
      syncWith = paired;
    }
    return (sender: sender, name: phoneName, paired: syncWith);
  }

  Future<void> _runCatalog() async {
    setState(() {
      _busy = true;
      _failed = false;
      _result = [];
      _progress = null;
      _status = 'Preparing album list...';
    });
    try {
      await _savePrefs();
      if (_adbPath.text.trim().isNotEmpty) await s.db.setSetting('adb_path', _adbPath.text.trim());
      final AlbumCatalog catalog;
      final String delivery;
      if (_method == Transport.usb) {
        await _loadUsb();
        final adb = _adb, serial = _serial;
        if (adb == null || serial == null) throw TransferException('No USB phone.');
        catalog = await sendAlbumCatalogOverUsb(UsbTransport(adb), serial, s.db);
        delivery = 'Copied to the phone inbox. Open beats-me and allow storage access to import it.';
      } else {
        final connection = await _connectPhone(pairedOnly: true);
        catalog = (await link.syncCatalog(connection.paired!,
            via: connection.sender.base, force: true))!;
        delivery = 'Album list synced to ${connection.name}.';
      }
      if (mounted) {
        setState(() => _result = [
              delivery,
              '${catalog.albums.length} albums; ${catalog.albums.where((a) => a.incomplete).length} incomplete.',
              'Search offline in beats-me > Own it?. No music files were copied.',
            ]);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _result = ['Could not send the album list: $e'];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
          _pairCode = null;
        });
      }
    }
  }

  /// Fetches plays & ratings from the phone after a send. Never fails the
  /// send: problems become a note.
  Future<String?> _syncJournal(PairedPhone phone, Uri via) async {
    if (mounted) setState(() => _status = 'Fetching plays & ratings from ${phone.name}…');
    try {
      final r = await link.syncJournal(phone, via: via);
      return [
        if (r != null && (r.plays > 0 || r.ratings > 0 || r.unmatched > 0)) 'From the phone: ${r.summary}.',
        ?link.lastCatalogSyncNote,
      ].join('\n');
    } catch (e) {
      debugPrint('Journal sync failed: $e');
      return 'ℹ Couldn\'t fetch plays & ratings from the phone ($e).';
    }
  }

  Future<List<String>> _toUsb(PackageWriter w, List<MixtapeSource> src, Directory cache) async {
    if (!_usbChecked) await _loadUsb();
    final adb = _adb;
    final serial = _serial;
    if (adb == null || serial == null) throw TransferException('No USB phone.');
    final pkg = labelDir(cache, Transport.usb, s.mixer.mixKey);
    await _write(w, Transport.usb, src, pkg);
    final usb = UsbTransport(adb);
    final r = await usb.send(serial, pkg,
        onProgress: (d, t, what) => _onProgress(d, t, what, 'Copying'), cancelled: _cancelled);
    return [
      'Copied ${r.sent} file(s), ${formatBytes(r.bytes)}; ${r.skipped} song(s) were already on the phone.',
      r.imported
          ? 'beats-me imported "$_name".'
          : 'beats-me didn’t confirm yet. Unlock the phone and open beats-me; it imports automatically.',
      await _syncPlaysOverUsb(usb, serial),
      await autoSyncAlbumCatalogOverUsb(usb, serial, s.db),
    ];
  }

  /// Picks up the phone's plays and ratings while it is connected; never
  /// fails the send.
  Future<String> _syncPlaysOverUsb(UsbTransport usb, String serial) async {
    try {
      final r = await syncJournalOverUsb(usb, serial, s.phoneSync());
      if (r == null) return 'No play history on the phone to sync yet.';
      if (r.ratings > 0) await s.refresh();
      return 'Phone history: ${r.summary}.';
    } catch (e) {
      return 'Couldn’t sync plays from the phone: $e';
    }
  }

  Future<List<String>> _servePull(PackageWriter w, List<MixtapeSource> src, Directory cache) async {
    await _write(w, Transport.pull, src, labelDir(cache, Transport.pull, s.mixer.mixKey));
    final l = await link.servePull(cache, _name);
    if (mounted) setState(() => _pullLink = l);
    return [
      'Ready. In beats-me tap Import › Scan QR code and point it at this code.',
      'The PC keeps serving after you close this window; stop it from the Mix screen.',
    ];
  }

  Future<List<String>> _toZip(PackageWriter w, List<MixtapeSource> src, Directory cache) async {
    final saved = await FilePicker.saveFile(
        dialogTitle: 'Save mixtape',
        fileName: '${sanitizeName(_name)}$mixtapeFileExt',
        bytes: Uint8List(0),
        type: FileType.custom,
        allowedExtensions: [mixtapeFileExt.substring(1)]);
    if (saved == null) return ['Cancelled.'];
    var path = saved.toFilePath();
    if (!path.toLowerCase().endsWith(mixtapeFileExt)) path = '$path$mixtapeFileExt';
    await ZipTransport.export(w,
        id: s.mixer.mixKey,
        name: _name,
        sourceName: link.pcName,
        sources: src,
        zipFile: File(path),
        cache: cache,
        transcodeId: _preset == 'copy' ? null : _preset,
        programName: s.mixer.program.name,
        icon: await _icon(),
        onProgress: (d, t, what) => _onProgress(d, t, what, 'Packing'),
        cancelled: _cancelled);
    if (mounted) setState(() => _savedFile = path);
    return [
      'Saved $path (${formatBytes(File(path).lengthSync())}).',
      'Send it to the phone any way you like: right-click › Share (Nearby sharing / Quick Share), '
          'email, Drive, or copy by cable. On the phone, tap the file and choose beats-me.',
    ];
  }

  Future<List<String>> _toFolder(PackageWriter w, List<MixtapeSource> src) async {
    final root = Directory(_folder!);
    final export = _method == Transport.folder ? FolderTransport.export : SyncdirTransport.export;
    await export(w,
        id: s.mixer.mixKey,
        name: _name,
        sourceName: link.pcName,
        sources: src,
        root: root,
        transcodeId: _preset == 'copy' ? null : _preset,
        programName: s.mixer.program.name,
        icon: await _icon(),
        onProgress: (d, t, what) => _onProgress(d, t, what, 'Writing'),
        cancelled: _cancelled);
    final out = labelDir(root, _method, s.mixer.mixKey).path;
    return [
      'Wrote ${src.length} songs to $out',
      _method == Transport.folder
          ? 'Copy that folder to the phone, then in beats-me tap Import › Folder.'
          : 'Once it has synced, beats-me imports it (Import › Advanced › Watch sync folder).',
    ];
  }

  // --------------------------------------------------------------------- UI

  String get _sendLabel => switch (_method) {
        Transport.push => _manualUri != null
            ? 'Send to ${_manualUri!.host}'
            : _phone == null
                ? 'Send over Wi-Fi'
                : 'Send to ${_phone!.name}',
        Transport.usb => 'Send over USB',
        Transport.pull => 'Show QR code',
        Transport.zip => 'Save .beatsmix…',
        Transport.folder => 'Export',
        _ => 'Export to sync folder',
      };

  Widget _methodTile(_Method m) => RadioListTile<String>(
        value: m.id,
        dense: true,
        contentPadding: EdgeInsets.zero,
        secondary: Icon(m.icon),
        title: Text(m.title),
        subtitle: Text(m.subtitle),
      );

  Widget _targetPicker() {
    switch (_method) {
      case Transport.push:
        final choices = link.choices;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Phone:'),
            const SizedBox(width: 8),
            Expanded(
              child: choices.isEmpty
                  ? Text(link.searching ? 'Searching…' : 'None found')
                  : DropdownButton<String>(
                      isExpanded: true,
                      value: _phoneId,
                      items: [
                        for (final c in choices)
                          DropdownMenuItem(
                              value: c.id,
                              child: Text('${c.name}'
                                  '${c.online ? '' : ' (not seen now)'}'
                                  '${c.paired == null ? ' – new' : ''}')),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() => _phoneId = v);
                              _recheck();
                            }),
            ),
            TextButton.icon(
                onPressed: _busy || link.searching ? null : _discover,
                icon: link.searching
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                label: const Text('Search')),
            if (_phone?.paired != null)
              IconButton(
                  tooltip: 'Forget this phone',
                  onPressed: _busy
                      ? null
                      : () async {
                          await link.forget(_phoneId!);
                          _recheck();
                        },
                  icon: const Icon(Icons.link_off)),
          ]),
        ]);
      case Transport.usb:
        if (_usb.length < 2) return const SizedBox.shrink();
        return Row(children: [
          const Text('Phone:'),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
                isExpanded: true,
                value: _serial,
                items: [
                  for (final d in _usb)
                    DropdownMenuItem(value: d.serial, child: Text('${d.label}${d.ready ? '' : ' (${d.state})'}')),
                ],
                onChanged: _busy
                    ? null
                    : (v) {
                        setState(() => _serial = v);
                        _recheck();
                      }),
          ),
        ]);
      case Transport.folder:
      case Transport.syncdir:
        return Row(children: [
          Expanded(child: Text(_folder ?? 'No folder chosen', overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: _busy ? null : _pickFolder, child: const Text('Choose folder…')),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _advanced() => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Advanced'),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          if (!widget.albumsOnly) DropdownButtonFormField<String>(
            initialValue: _preset,
            decoration: const InputDecoration(labelText: 'Songs', isDense: true),
            items: [
              const DropdownMenuItem(
                  value: TranscodePreset.autoId,
                  child: Text('Auto: copy, convert only what Android can’t play')),
              const DropdownMenuItem(value: 'copy', child: Text('Copy originals as they are')),
              for (final t in TranscodePreset.presets)
                DropdownMenuItem(value: t.id, child: Text('Convert all to ${t.label} (smaller)')),
            ],
            onChanged: _busy
                ? null
                : (v) {
                    setState(() => _preset = v ?? TranscodePreset.autoId);
                    _recheck();
                  },
          ),
          if (!widget.albumsOnly) TextField(
              controller: _ffmpeg,
              decoration: const InputDecoration(labelText: 'ffmpeg path (for converting)', isDense: true),
              onChanged: (_) => _recheck()),
          if (_method == Transport.usb)
            TextField(
                controller: _adbPath,
                decoration: const InputDecoration(labelText: 'adb path', isDense: true),
                onChanged: (_) => _recheck()),
          if (_method == Transport.push) ...[
            TextField(
                controller: _manualAddr,
                decoration: const InputDecoration(
                    labelText: 'Phone address, if it isn’t found (shown on the phone, e.g. 192.168.1.20:47820)',
                    isDense: true),
                onChanged: (_) {
                  setState(() {});
                  _recheck();
                }),
            TextField(
                controller: _manualCode,
                decoration: const InputDecoration(
                    labelText: 'Code shown on the phone (leave empty to pair instead)', isDense: true)),
          ],
          if (!widget.albumsOnly && link.paired.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Paired phones: ${link.paired.map((p) => p.name).join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
        ],
      );

  Widget _checkRow(_Check c) {
    final (icon, color) = switch (c.level) {
      _Level.ok => (Icons.check_circle, Colors.green),
      _Level.info => (Icons.info_outline, Colors.blueGrey),
      _Level.warn => (Icons.warning_amber, Colors.orange),
      _Level.error => (Icons.error, Colors.red),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(c.text)),
      ]),
    );
  }

  Widget _pullPanel() {
    final l = _pullLink;
    if (l == null || _method != Transport.pull) return const SizedBox.shrink();
    final rep = link.lastPullReport;
    return Column(children: [
      const SizedBox(height: 8),
      Center(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(8),
          child: QrImageView(data: l.toString(), size: 220),
        ),
      ),
      SelectableText('Or enter in beats-me: ${l.hosts.isEmpty ? '?' : l.hosts.first}:${l.port}  code ${l.token}',
          textAlign: TextAlign.center),
      if (rep != null && rep.id == s.mixer.mixKey)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              '✓ Phone imported it: ${rep.report['copied'] ?? 0} new, ${rep.report['reused'] ?? 0} already there'
              '${(rep.report['errors'] as List?)?.isNotEmpty ?? false ? ', ${(rep.report['errors'] as List).length} errors' : ''}.',
              style: const TextStyle(color: Colors.green)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.albumsOnly ? 'Send album list to phone' : 'Send "$_name" to phone'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            RadioGroup<String>(
              groupValue: _method,
              onChanged: (v) => _pick(v!),
              child: Column(children: [
                for (final m in _primary)
                  if (!widget.albumsOnly || m.id == Transport.push || m.id == Transport.usb) _methodTile(m),
                if (_showMore) for (final m in _more) _methodTile(m),
              ]),
            ),
            if (!_showMore && !widget.albumsOnly)
              TextButton(
                  onPressed: () => setState(() => _showMore = true), child: const Text('More methods…')),
            _targetPicker(),
            const Divider(),
            Row(children: [
              Text('Checks', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              if (_checking) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const Spacer(),
              if (!_busy)
                IconButton(
                    tooltip: 'Check again',
                    visualDensity: VisualDensity.compact,
                    onPressed: _recheck,
                    icon: const Icon(Icons.refresh, size: 18)),
            ]),
            for (final c in _checks) _checkRow(c),
            _advanced(),
            if (_pairCode != null)
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    const Text('On the phone, tap Allow. It should show this code:'),
                    Text(_pairCode!, style: Theme.of(context).textTheme.headlineMedium),
                  ]),
                ),
              ),
            if (_busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
              if (_status.isNotEmpty) Text(_status, overflow: TextOverflow.ellipsis),
            ],
            if (_result.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final l in _result)
                    SelectableText(l, style: _failed ? const TextStyle(color: Colors.red) : null),
                ]),
              ),
            if (_savedFile != null)
              TextButton.icon(
                  onPressed: () => Process.run('explorer.exe', ['/select,', _savedFile!]),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Show in folder')),
            _pullPanel(),
          ]),
        ),
      ),
      actions: [
        if (_busy) TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_busy ? 'Hide' : 'Close')),
        if (!widget.albumsOnly && (_method == Transport.push || _method == Transport.usb))
          TextButton.icon(
              onPressed: _busy ? null : _runCatalog,
              icon: const Icon(Icons.album_outlined),
              label: const Text('Send album list')),
        FilledButton.icon(
            onPressed: _busy || _blocked ? null : _run,
            icon: Icon(_failed ? Icons.replay : Icons.send),
            label: Text(_failed ? 'Try again' : widget.albumsOnly ? 'Send album list' : _sendLabel)),
      ],
    );
  }
}

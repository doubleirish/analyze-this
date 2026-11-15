import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;
import 'package:shared_core/shared_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where playback goes: a local audio output (speakers, Bluetooth headphones,
/// anything Windows lists) or a Chromecast / Google Cast device.
class OutputController extends ChangeNotifier {
  OutputController(this.playback);

  final PlaybackController playback;

  static const _kDevice = 'outDevice';
  static const _kDelay = 'outDelay:';

  SharedPreferences? _prefs;
  List<AudioDevice> localDevices = [];
  AudioDevice local = AudioDevice.auto();
  List<CastDevice> castDevices = [];
  bool scanning = false;
  CastDevice? casting;
  CastDevice? connecting;
  String? error;
  CastRenderer? _renderer;

  PlayerEngine get _engine => playback.player;

  bool get isCasting => casting != null;

  /// Extra delay (ms) for the current local output, e.g. Bluetooth latency.
  int get delayMs => _prefs?.getInt('$_kDelay${local.name}') ?? 0;

  /// Restores the saved local output if it is still available.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await refreshLocal();
    final saved = _prefs!.getString(_kDevice);
    final match = localDevices.where((d) => d.name == saved);
    if (match.isNotEmpty) {
      await selectLocal(match.first, save: false);
    } else {
      _applyDelay();
    }
  }

  /// Reloads the list of local audio outputs (new Bluetooth devices appear here).
  Future<void> refreshLocal() async {
    for (var i = 0; i < 30 && JustAudioMediaKit.players.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final players = JustAudioMediaKit.players;
    if (players.isNotEmpty) {
      localDevices = players.first.state.audioDevices.where((d) => d.name != 'auto').toList();
    }
    notifyListeners();
  }

  Future<void> selectDefault() => selectLocal(AudioDevice.auto());

  Future<void> selectLocal(AudioDevice device, {bool save = true}) async {
    error = null;
    if (isCasting) await stopCasting();
    local = device;
    await JustAudioMediaKit.setAudioDevice(device);
    if (save) await _prefs?.setString(_kDevice, device.name);
    _applyDelay();
    notifyListeners();
  }

  void _applyDelay() => _engine.outputDelay = Duration(milliseconds: delayMs);

  Future<void> setDelayMs(int ms) async {
    await _prefs?.setInt('$_kDelay${local.name}', ms);
    _applyDelay();
    notifyListeners();
  }

  Future<void> scanCast() async {
    if (scanning) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      castDevices = await discoverCastDevices();
      if (castDevices.isEmpty) error = 'No cast devices found on this network.';
    } catch (e) {
      error = 'Could not search for cast devices: $e';
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> cast(CastDevice device) async {
    if (connecting != null) return;
    error = null;
    connecting = device;
    notifyListeners();
    final old = _renderer;
    final r = CastRenderer(device, info: _info);
    r.onError = (e) => unawaited(_castFailed(r, e));
    try {
      await _engine.useRemote(r);
      _renderer = r;
      casting = device;
      _engine.outputDelay = Duration.zero;
    } catch (e) {
      error = 'Could not play on ${device.name}: $e';
      unawaited(r.stop().catchError((_) {}));
      _renderer = old;
    } finally {
      connecting = null;
      notifyListeners();
    }
  }

  Future<CastTrackInfo> _info(String path) async {
    // Art and lyrics load asynchronously; wait briefly so the first load has them.
    if (!playback.media.containsKey(path)) {
      await playback.ensureMedia(path).timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    final m = playback.media[path];
    return (title: m?.title, artist: m?.artist, album: m?.album, art: m?.art, lyrics: m?.lyrics);
  }

  Future<void> _castFailed(CastRenderer r, Object e) async {
    if (!identical(r, _renderer)) return;
    error = '${r.device.name}: $e. Playing on this computer again.';
    await _backToLocal();
  }

  Future<void> stopCasting() async {
    if (!isCasting) return;
    await _backToLocal();
  }

  Future<void> _backToLocal() async {
    _renderer = null;
    casting = null;
    try {
      await _engine.useRemote(null);
    } catch (_) {}
    _applyDelay();
    notifyListeners();
  }
}

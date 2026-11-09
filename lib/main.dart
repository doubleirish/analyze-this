import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/shared_core.dart';

import 'screens/home_screen.dart';
import 'services/album_health_controller.dart';
import 'services/app_state.dart';
import 'services/art_controller.dart';
import 'services/backup.dart';
import 'services/damage_scan.dart';
import 'services/db.dart';
import 'services/mix_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final dbPath = p.join(dir.path, 'analyze_this.db');
  await BackupService.applyPendingRestore(dir, dbPath);
  final db = await MusicDb.open(dbPath);
  final state = AppState(db)..backups = BackupService(db, dir);
  await state.load();
  await state.initPlayback();
  unawaited(state.backups.autoBackupIfDue().catchError((_) => null));
  runApp(MultiProvider(providers: [
    ChangeNotifierProvider<AppState>.value(value: state),
    ChangeNotifierProvider<PlaybackController>.value(value: state),
    ChangeNotifierProvider<MixController>.value(value: state.mixer),
    ChangeNotifierProvider<AlbumHealthController>.value(value: state.health),
    ChangeNotifierProvider<DamageScanController>.value(value: state.damage),
    ChangeNotifierProvider<ArtController>.value(value: state.artwork),
  ], child: const AnalyzeThisApp()));
}

class AnalyzeThisApp extends StatelessWidget {
  const AnalyzeThisApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'analyze-this',
        theme: ThemeData(
            colorSchemeSeed: Colors.deepOrange,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const HomeScreen(),
      );
}


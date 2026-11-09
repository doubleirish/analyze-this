import 'package:shared_core/shared_core.dart';

import 'album_catalog.dart';
import 'db.dart';
import 'phone_sync.dart';

/// Reads beats-me's play/rating journal over adb, imports it and acks what
/// was imported so the phone can trim it. Null when the phone has no journal
/// mirror (beats-me not run yet, or no storage permission).
Future<PhoneSyncResult?> syncJournalOverUsb(UsbTransport usb, String serial, PhoneSync sync) async {
  final text = await usb.readJournal(serial);
  if (text == null) return null;
  final r = await sync.importJournalByDevice(text);
  if (r.ackSeq > 0) await usb.ackJournal(serial, r.ackSeq);
  return r;
}

/// Outcome of [syncFromUsbPhone]: [result] is null when nothing was synced
/// and [message] explains why.
typedef UsbSyncOutcome = ({PhoneSyncResult? result, String message});

Future<AlbumCatalog> sendAlbumCatalogOverUsb(UsbTransport usb, String serial, MusicDb db) async {
  final catalog = buildAlbumCatalog(await db.albumCatalogSongs());
  await usb.sendCatalog(serial, catalog);
  return catalog;
}

/// USB only confirms delivery to the inbox, so do not cache a "synced" hash.
Future<String> autoSyncAlbumCatalogOverUsb(UsbTransport usb, String serial, MusicDb db) async {
  try {
    final catalog = await sendAlbumCatalogOverUsb(usb, serial, db);
    return 'Album list copied (${catalog.albums.length} albums). Open beats-me to import it.';
  } catch (e) {
    return 'Could not copy the album list: $e';
  }
}

/// Finds adb (the saved `adb_path` first) and the first ready phone, then
/// runs [syncJournalOverUsb].
Future<UsbSyncOutcome> syncFromUsbPhone(MusicDb db, PhoneSync sync) async {
  final saved = (await db.setting('adb_path'))?.trim() ?? '';
  final adb = await UsbTransport.findAdb([if (saved.isNotEmpty) saved]);
  if (adb == null) {
    return (
      result: null,
      message: 'adb not found. Install Android platform-tools, or set its path in Send to phone › USB.'
    );
  }
  final usb = UsbTransport(adb);
  final devices = await usb.devices();
  if (devices.isEmpty) {
    return (result: null, message: 'No phone found. Connect it by USB with USB debugging on.');
  }
  final d = devices.where((d) => d.ready).firstOrNull;
  if (d == null) return (result: null, message: devices.first.advice);
  final r = await syncJournalOverUsb(usb, d.serial, sync);
  final catalogNote = await autoSyncAlbumCatalogOverUsb(usb, d.serial, db);
  if (r == null) {
    return (
      result: null,
      message: 'No play journal on ${d.label}. Open beats-me and allow storage access, then try again.\n$catalogNote'
    );
  }
  return (result: r, message: '${d.label}: ${r.summary}\n$catalogNote');
}

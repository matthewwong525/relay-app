import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../data/api.dart';
import '../data/connection.dart';
import '../data/outbox.dart';
import '../data/store.dart';
import 'health.dart';

/// The hourly task's name; iPhone also lists it in Info.plist and AppDelegate.swift.
const syncTask = 'com.matthewwong525.relay.sync';

// The app and the background round share one connection, so their writes never collide.
Store openStore() => Store(driftDatabase(name: 'relay', native: const DriftNativeOptions(shareAcrossIsolates: true)));

/// The background round: health since the last read, the location points kept, then every waiting upload.
@pragma('vm:entry-point')
void backgroundSync() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final connection = await KeyVault().read();
    if (connection == null) return true;
    final store = openStore();
    try {
      final settings = await store.get('settings');
      if (settings?.contains('"health":true') ?? false) await syncHealth(store, PhoneHealth());
      await store.queuePoints();
      return (await flush(store, RelayApi(connection))).failure == null;
    } on Exception {
      return false;
    } finally {
      await store.close();
    }
  });
}

/// Turns the hourly round on when history or health is on, and off when neither is.
Future<void> scheduleSync(bool on) async {
  if (!on) return Workmanager().cancelByUniqueName(syncTask);
  await Workmanager().registerPeriodicTask(syncTask, syncTask, frequency: const Duration(hours: 1),
    constraints: Constraints(networkType: NetworkType.connected), existingWorkPolicy: ExistingPeriodicWorkPolicy.keep);
}

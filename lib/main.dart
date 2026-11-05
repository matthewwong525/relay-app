import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'controller.dart';
import 'data/connection.dart';
import 'sync/background.dart';
import 'sync/health.dart';
import 'sync/location.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Workmanager().initialize(backgroundSync);
  final relay = RelayController(store: openStore(), vault: KeyVault(), places: PhonePlaces(), health: PhoneHealth(), schedule: scheduleSync);
  await relay.load();
  runApp(RelayApp(relay: relay));
  // Each open, and each return to the app, sends what waits and reads the newest notes.
  AppLifecycleListener(onResume: relay.sync);
  await relay.sync();
}

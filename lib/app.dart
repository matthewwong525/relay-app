import 'package:flutter/material.dart';

import 'relay.dart';
import 'screens/connect.dart';
import 'screens/timeline.dart';

/// Connect first; once a key is kept, the timeline.
class RelayApp extends StatelessWidget {
  const RelayApp({super.key, required this.relay, this.scanner});

  final Relay relay;
  final Future<String?> Function(BuildContext context)? scanner;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Relay',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
      home: ListenableBuilder(
        listenable: relay,
        builder: (context, _) => relay.connected
          ? TimelineScreen(relay: relay)
          : scanner == null ? ConnectScreen(relay: relay) : ConnectScreen(relay: relay, scanner: scanner!),
      ),
    );
  }
}

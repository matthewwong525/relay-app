import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/app.dart';
import 'package:relay_app/relay.dart';

class FakeRelay extends Relay {
  @override bool connected = false;
  @override String? server;
  @override List<Entry> entries = [];
  @override bool hasMore = false;
  @override SyncStatus status = SyncStatus.synced;
  @override int waiting = 0;
  @override Settings settings = const Settings();
  final calls = <String>[];
  String? problem;

  void changed() => notifyListeners();

  @override
  Future<String?> connect(String code) async {
    calls.add('connect $code');
    if (problem == null) {
      connected = true;
      notifyListeners();
    }
    return problem;
  }

  @override Future<String?> setServer(String server) async { calls.add('server $server'); return problem; }
  @override Future<String?> setPinNotes(bool on) async { calls.add('pin $on'); return problem; }
  @override Future<String?> setHistory(bool on) async { calls.add('history $on'); return problem; }
  @override Future<String?> setHealth(bool on) async { calls.add('health $on'); return problem; }
  @override Future<void> disconnect() async { calls.add('disconnect'); connected = false; notifyListeners(); }
  @override Future<void> sync() async => calls.add('sync');
  @override Future<void> more() async => calls.add('more');
  @override Future<void> addNote(String text) async => calls.add('note $text');
}

final now = DateTime.now();

void main() {
  late FakeRelay relay;
  setUp(() => relay = FakeRelay());

  testWidgets('connects by a pasted key, and says why one is refused', (tester) async {
    await tester.pumpWidget(RelayApp(relay: relay));
    relay.problem = 'That is not a Relay key.';
    await tester.enterText(find.byType(TextField), 'nonsense');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('That is not a Relay key.'), findsOneWidget);
    relay.problem = null;
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(relay.calls, ['connect nonsense', 'connect nonsense']);
    expect(find.text('New note'), findsOneWidget);
  });

  testWidgets('connects by a scanned key, and does nothing when the scan is closed', (tester) async {
    String? scanned;
    await tester.pumpWidget(RelayApp(relay: relay, scanner: (_) async => scanned));
    await tester.tap(find.text('Scan the QR code'));
    await tester.pumpAndSettle();
    expect(relay.calls, isEmpty);
    scanned = '{"relay":1}';
    await tester.tap(find.text('Scan the QR code'));
    await tester.pumpAndSettle();
    expect(relay.calls, ['connect {"relay":1}']);
  });

  testWidgets('shows each note with its source, place and waiting state, and older ones on request', (tester) async {
    relay
      ..connected = true
      ..hasMore = true
      ..waiting = 1
      ..entries = [
        Entry(text: 'Lunch idea', ring: false, at: now, place: 'King St W', waiting: true),
        Entry(text: '', ring: true, at: DateTime(2026, 1, 2, 9), place: 'Harbord St', device: 'Pebble app', audio: true),
      ];
    await tester.pumpWidget(RelayApp(relay: relay));
    expect(find.text('Typed'), findsOneWidget);
    expect(find.text('Ring'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('No words, only the recording.'), findsOneWidget);
    expect(find.textContaining('Harbord St · Pebble app'), findsOneWidget);
    expect(find.textContaining('Jan 2'), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.text('1 waiting'), findsOneWidget);
    await tester.tap(find.text('Show older notes'));
    await tester.tap(find.text('1 waiting'));
    expect(relay.calls, ['more', 'sync']);
  });

  testWidgets('names each sync state, and an empty timeline in words', (tester) async {
    relay.connected = true;
    await tester.pumpWidget(RelayApp(relay: relay));
    expect(find.textContaining('No notes yet'), findsOneWidget);
    for (final (status, waiting, label) in [(SyncStatus.syncing, 0, 'Syncing'), (SyncStatus.refused, 0, 'Key refused'),
      (SyncStatus.offline, 0, 'Offline'), (SyncStatus.offline, 2, '2 waiting'), (SyncStatus.idle, 0, 'Synced')]) {
      relay
        ..status = status
        ..waiting = waiting
        ..changed();
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.drag(find.textContaining('No notes yet'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(relay.calls, ['sync']);
  });

  testWidgets('saves a typed note once it has words', (tester) async {
    relay.connected = true;
    await tester.pumpWidget(RelayApp(relay: relay));
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(relay.calls, ['note Buy milk']);
    expect(find.text('New note'), findsOneWidget);
  });

  testWidgets('turns settings on and says why one could not be', (tester) async {
    relay
      ..connected = true
      ..server = 'https://relay.example.com';
    await tester.pumpWidget(RelayApp(relay: relay));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin notes to a place'));
    await tester.tap(find.text('Location history'));
    relay.problem = 'Relay may not read your health data.';
    await tester.tap(find.text('Health'));
    await tester.pump();
    expect(find.text('Relay may not read your health data.'), findsOneWidget);
    expect(relay.calls, ['pin false', 'history true', 'health true']);
  });

  testWidgets('changes the server, and disconnects after asking', (tester) async {
    relay
      ..connected = true
      ..server = 'https://relay.example.com';
    await tester.pumpWidget(RelayApp(relay: relay));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('https://relay.example.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('https://relay.example.com'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://preview.example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect this phone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect this phone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(relay.calls, ['server https://preview.example.com', 'disconnect']);
    expect(find.text('Connect Relay'), findsOneWidget);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:relay_app/controller.dart';
import 'package:relay_app/data/connection.dart';
import 'package:relay_app/data/store.dart';
import 'package:relay_app/relay.dart';

import 'fakes.dart';

final now = DateTime.fromMillisecondsSinceEpoch(1793797200000);
final ring = {'id': 'a', 'source': 'ring', 'text': 'Call the PCB fab', 'recordedAt': 1793797100000, 'device': 'Pebble app', 'audio': true,
  'place': {'lat': 43.66, 'lon': -79.39, 'accuracy': 15, 'name': 'Harbord St', 'from': 'history'}};

void main() {
  late Store store;
  late MemoryStorage storage;
  late FakeServer server;
  late FakePlaces places;
  late FakeHealth health;
  late List<bool> scheduled;

  RelayController controller() => RelayController(store: store, vault: KeyVault(storage), places: places, health: health,
    apiFor: server.api, clock: () => now, schedule: (on) async => scheduled.add(on));

  setUp(() {
    store = memoryStore();
    storage = MemoryStorage();
    server = FakeServer((request) => request.url.path.endsWith('timeline')
      ? FakeServer.json({'notes': [ring], 'next': request.url.queryParameters.containsKey('before') ? null : 1793797100000, 'nextId': 'a'})
      : FakeServer.ok(request));
    places = FakePlaces();
    health = FakeHealth();
    scheduled = [];
  });
  tearDown(() => store.close());

  test('connects with a key the server takes, and syncs at once', () async {
    final relay = controller();
    await relay.load();
    expect(relay.connected, isFalse);
    expect(await relay.connect('nonsense'), contains('not a Relay key'));
    expect(await relay.connect(code), isNull);
    await relay.sync();
    expect(relay.connected, isTrue);
    expect(relay.server, 'https://relay.example.com');
    expect(storage.values.values, contains('secret-value'));
    expect(relay.status, SyncStatus.synced);
    expect([relay.entries.single.text, relay.entries.single.place, relay.entries.single.ring], ['Call the PCB fab', 'Harbord St', true]);
    expect(relay.hasMore, isTrue);
    await relay.more();
    expect(server.requests.last.url.queryParameters, {'before': '1793797100000', 'beforeId': 'a'});
    expect(relay.entries, hasLength(2));
    expect(relay.hasMore, isFalse);
    await relay.more();
    expect(server.requests.where((request) => request.url.path.endsWith('timeline')), hasLength(3));
  });

  test('refuses a key the server turns down, and keeps one it could not try', () async {
    final relay = controller();
    server.answer = (_) => FakeServer.json({}, 403);
    expect(await relay.connect(code), contains('did not take this key'));
    expect(relay.connected, isFalse);
    server.answer = (_) => FakeServer.json({}, 503);
    expect(await relay.connect(code), isNull);
    await relay.sync();
    expect([relay.connected, relay.status], [true, SyncStatus.offline]);
  });

  test('shows a note at once as waiting, with its pin, and on the server after the next sync', () async {
    await KeyVault(storage).save(connection);
    places.pin = Pin(at: now, lat: 43.64871, lon: -79.38171, accuracy: 12);
    server.answer = (_) => FakeServer.json({}, 503);
    final relay = controller();
    await relay.load();
    await relay.addNote('  Lunch idea  ');
    await pumpEventQueue();
    await relay.sync();
    expect([relay.entries.single.text, relay.entries.single.waiting, relay.entries.single.place], ['Lunch idea', true, '43.6487, -79.3817']);
    expect([relay.status, relay.waiting], [SyncStatus.offline, 1]);
    server.answer = (request) => request.url.path.endsWith('timeline') ? FakeServer.json({'notes': [ring], 'next': null}) : FakeServer.ok(request);
    await relay.sync();
    expect([relay.entries.single.text, relay.waiting, relay.status], ['Call the PCB fab', 0, SyncStatus.synced]);
    final sent = jsonDecode(server.requests.firstWhere((request) => request.url.path.endsWith('notes')).body) as Map<String, dynamic>;
    expect(sent, containsPair('createdAt', 1793797200000));
    expect(sent['clientId'], matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('asks for location once, right after the phone connects, as pins start on', () async {
    final relay = controller();
    await relay.load();
    server.answer = (_) => FakeServer.json({}, 403);
    expect(await relay.connect(code), contains('did not take this key'));
    expect(places.asked, isEmpty);
    server.answer = FakeServer.ok;
    places.allowed = false;
    expect(await relay.connect(code), isNull);
    expect([places.asked, relay.settings.pinNotes, relay.connected], [[false], true, true]);
    await relay.disconnect();
    expect(await relay.setPinNotes(false), isNull);
    places.asked.clear();
    expect(await relay.connect(code), isNull);
    expect(places.asked, isEmpty);
  });

  test('keeps a note at once, and adds its pin when the phone has a fix', () async {
    await KeyVault(storage).save(connection);
    server.answer = (_) => FakeServer.json({}, 503);
    places.fix = Completer();
    final relay = controller();
    await relay.load();
    await relay.addNote('Bench idea');
    expect([relay.entries.single.text, relay.entries.single.place, relay.waiting], ['Bench idea', null, 1]);
    places.fix!.complete(Pin(at: now, lat: 43.64871, lon: -79.38171, accuracy: 12, place: 'Queen St W'));
    await pumpEventQueue();
    expect(relay.entries.single.place, 'Queen St W');
    final sent = jsonDecode(server.requests.firstWhere((request) => request.url.path.endsWith('notes')).body) as Map<String, dynamic>;
    expect([sent['text'], sent['lat'], sent['place']], ['Bench idea', 43.64871, 'Queen St W']);
    // A note not waiting, such as one sent already, keeps no late pin.
    expect(await store.queueNote('gone', Pin(at: now, lat: 1, lon: 1, accuracy: 1)), isFalse);
  });

  test('a second note syncs while the first waits for its pin, and the first goes later with its place', () async {
    await KeyVault(storage).save(connection);
    final first = Completer<Pin?>();
    places.fix = first;
    final relay = controller();
    await relay.load();
    await relay.addNote('First');
    await pumpEventQueue();
    places
      ..fix = null
      ..pin = Pin(at: now, lat: 43.65, lon: -79.40, accuracy: 8, place: 'Ossington Ave');
    await relay.addNote('Second');
    await pumpEventQueue();
    await relay.sync(); // pull to refresh, the sync chip or the app's return
    List<Map<String, dynamic>> sent() => [
      for (final request in server.requests) if (request.url.path.endsWith('notes')) jsonDecode(request.body) as Map<String, dynamic>,
    ];
    expect([for (final note in sent()) note['text']], ['Second']);
    expect(sent().single['place'], 'Ossington Ave');
    expect([relay.waiting, for (final entry in relay.entries) if (entry.waiting) entry.text], [1, 'First']);
    first.complete(Pin(at: now, lat: 43.64871, lon: -79.38171, accuracy: 12, place: 'Queen St W'));
    await pumpEventQueue();
    await relay.sync();
    expect([for (final note in sent()) note['text']], ['Second', 'First']);
    expect([sent().last['lat'], sent().last['place']], [43.64871, 'Queen St W']);
    expect(relay.waiting, 0);
  });

  test('a note goes without a place when the phone gives up, or when the app closed while it waited', () async {
    await KeyVault(storage).save(connection);
    final relay = controller();
    await relay.load();
    await relay.addNote('No fix');
    await pumpEventQueue();
    await relay.sync();
    expect(jsonDecode(server.requests.firstWhere((request) => request.url.path.endsWith('notes')).body), isNot(contains('lat')));
    await store.addNote(LocalNote(clientId: 'closed', text: 'Cut short', createdAt: now), waitForPin: true);
    expect([(await store.outbox()).length, await store.waiting()], [0, 1]);
    await controller().load();
    expect((await store.outbox()).single.body, {'clientId': 'closed', 'text': 'Cut short', 'createdAt': now.millisecondsSinceEpoch});
  });

  test('opens with the last timeline and settings it saw, with no network', () async {
    await KeyVault(storage).save(connection);
    await store.set('timeline', jsonEncode([ring]));
    await store.set('settings', jsonEncode({'pinNotes': false, 'history': true, 'health': true}));
    final relay = controller();
    await relay.load();
    expect(relay.entries.single.text, 'Call the PCB fab');
    expect([relay.settings.pinNotes, relay.settings.history, relay.settings.health], [false, true, true]);
    places.points.add(Pin(at: now, lat: 43.6, lon: -79.3, accuracy: 9));
    await pumpEventQueue();
    await relay.addNote('No pin');
    await relay.sync();
    final routes = server.routes;
    expect(routes, containsAll(['notes', 'locations', 'timeline']));
    expect(jsonDecode(server.requests.firstWhere((request) => request.url.path.endsWith('notes')).body), isNot(contains('lat')));
    relay.dispose();
  });

  test('turns each setting on only with its permission, and schedules the hourly sync', () async {
    final relay = controller();
    await relay.load();
    places.allowed = false;
    health.allowed = false;
    expect(await relay.setPinNotes(true), contains('location'));
    expect(await relay.setHistory(true), contains('all the time'));
    expect(await relay.setHealth(true), contains('health'));
    expect([relay.settings.history, relay.settings.health], [false, false]);
    expect(await relay.setPinNotes(false), isNull);
    places.allowed = true;
    health.allowed = true;
    expect(await relay.setHistory(true), isNull);
    expect(await relay.setHealth(true), isNull);
    expect(await relay.setHistory(false), isNull);
    expect(await relay.setPinNotes(true), isNull);
    expect(scheduled, [false, true, true, true, true]);
    expect(jsonDecode((await store.get('settings'))!), {'pinNotes': true, 'history': false, 'health': true});
  });

  test('sends health on each sync, and goes on when the health store is closed', () async {
    await KeyVault(storage).save(connection);
    await store.set('settings', jsonEncode({'pinNotes': true, 'history': false, 'health': true}));
    final relay = controller();
    await relay.load();
    health.readings = [reading(HealthDataType.STEPS, now.subtract(const Duration(hours: 1)), now, value: 100)];
    await relay.sync();
    expect(server.routes.first, 'health');
    health.error = Exception('locked');
    await relay.sync();
    expect(relay.status, SyncStatus.synced);
  });

  test('says when the key is refused, or the timeline or an older page can not be read', () async {
    await KeyVault(storage).save(connection);
    final relay = controller();
    await relay.load();
    await relay.sync();
    server.answer = (_) => FakeServer.json({}, 401);
    await relay.addNote('x');
    await relay.sync();
    expect(relay.status, SyncStatus.refused);
    server.answer = (request) => request.url.path.endsWith('timeline') ? FakeServer.json({}, 401) : FakeServer.ok(request);
    await relay.sync();
    expect(relay.status, SyncStatus.refused);
    server.answer = (request) => request.url.path.endsWith('timeline') ? FakeServer.json({}, 502) : FakeServer.ok(request);
    await relay.sync();
    expect(relay.status, SyncStatus.offline);
    await relay.more();
    expect(relay.status, SyncStatus.offline);
  });

  test('changes the server, and disconnects keeping notes not sent', () async {
    final relay = controller();
    expect(await relay.setServer('https://preview.example.com'), 'Connect a key first.');
    await KeyVault(storage).save(connection);
    await relay.load();
    expect(await relay.setServer('preview.example.com'), contains('https://'));
    expect(await relay.setServer('https://preview.example.com/'), isNull);
    expect(relay.server, 'https://preview.example.com');
    server.answer = (_) => FakeServer.json({}, 503);
    await relay.addNote('Kept');
    await relay.disconnect();
    expect([relay.connected, relay.status, relay.hasMore], [false, SyncStatus.idle, false]);
    expect(storage.values, isEmpty);
    expect(relay.entries.single.text, 'Kept');
    await relay.sync();
    await relay.more();
    expect(server.requests.every((request) => request.url.host == 'preview.example.com'), isTrue);
  });

  test('makes a note id the server takes', () {
    expect(newClientId(Random(1)), matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(newClientId(), isNot(newClientId()));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_app/data/api.dart';
import 'package:relay_app/data/connection.dart';
import 'package:relay_app/data/outbox.dart';
import 'package:relay_app/data/store.dart';

import 'fakes.dart';

final at = DateTime.fromMillisecondsSinceEpoch(1793797200000);

void main() {
  group('a key', () {
    test('is read from its QR code, scanned or pasted', () {
      final parsed = Connection.parse(' $code\n')!;
      expect([parsed.server, parsed.clientId, parsed.clientSecret], [connection.server, connection.clientId, connection.clientSecret]);
    });

    test('is refused when it is not whole, not https, or not Relay\'s', () {
      Map<String, Object?> with_(Map<String, Object?> change) =>
        {'relay': 1, 'server': 'https://relay.example.com', 'clientId': 'a', 'clientSecret': 'b', ...change};
      for (final text in ['', 'not json', '[1]', jsonEncode(with_({'relay': 2})), jsonEncode(with_({'server': 'http://relay.example.com'})),
        jsonEncode(with_({'server': 'https://relay.example.com/apps'})), jsonEncode(with_({'clientId': ''})), jsonEncode(with_({'clientSecret': 3}))]) {
        expect(Connection.parse(text), isNull, reason: text);
      }
    });

    test('keeps a server address as its origin alone', () {
      expect(Connection.serverOf('https://preview.example.com/'), 'https://preview.example.com');
      for (final value in [null, 3, 'preview.example.com', 'https://', 'https://x.example.com?a=1']) {
        expect(Connection.serverOf(value), isNull, reason: '$value');
      }
    });

    test('lives in the secure store, and is forgotten whole', () async {
      final storage = MemoryStorage();
      final vault = KeyVault(storage);
      expect(await vault.read(), isNull);
      await vault.save(connection);
      expect((await vault.read())!.clientSecret, connection.clientSecret);
      await vault.forget();
      expect(storage.values, isEmpty);
    });
  });

  group('the API', () {
    test('sends the key in both Access headers, and the body as JSON', () async {
      final server = FakeServer();
      expect(await server.api(connection).post('notes', {'text': 'hi'}), {'added': 1});
      final request = server.requests.single;
      expect(request.url.toString(), 'https://relay.example.com/apps/relay/api/notes');
      expect(request.headers['CF-Access-Client-Id'], 'phone.access');
      expect(request.headers['CF-Access-Client-Secret'], 'secret-value');
      expect(jsonDecode(request.body), {'text': 'hi'});
    });

    test('reads the timeline with each place as a name or coordinates', () async {
      final server = FakeServer((_) => FakeServer.json({'notes': [
        {'id': 'a', 'source': 'ring', 'text': '', 'recordedAt': 1793797260000, 'device': 'Pebble app', 'audio': true,
          'place': {'lat': 43.66291, 'lon': -79.39572, 'accuracy': null, 'name': null, 'from': 'history'}},
        {'id': 'b', 'source': 'typed', 'text': 'Hi', 'recordedAt': 1793797200000, 'device': 'Phone', 'audio': false,
          'place': {'lat': 43.6, 'lon': -79.3, 'accuracy': 5, 'name': 'King St W', 'from': 'phone'}},
        {'id': 'c', 'source': 'typed', 'text': 'No place', 'recordedAt': 1793797100000, 'device': 'Phone', 'audio': false, 'place': null},
      ], 'next': 1793797100000, 'nextId': 'c'}));
      final page = await server.api(connection).timeline(before: (at: 1793797300000, id: 'd'));
      expect(server.requests.single.url.queryParameters, {'before': '1793797300000', 'beforeId': 'd'});
      expect([for (final note in page.notes) note.place], ['43.6629, -79.3957', 'King St W', null]);
      expect(page.notes.first.audio, isTrue);
      expect(page.notes.first.json['id'], 'a');
      expect(page.next, (at: 1793797100000, id: 'c'));
    });

    test('names each failure: a refused key, a body turned down, or no answer', () async {
      Future<Failure?> failureOf(http.Response response) async {
        try {
          await FakeServer((_) => response).api(connection).post('notes', {});
          return null;
        } on ApiException catch (error) {
          return error.failure;
        }
      }
      expect(await failureOf(http.Response('', 401)), Failure.refused);
      expect(await failureOf(http.Response('', 403)), Failure.refused);
      expect(await failureOf(http.Response('', 302)), Failure.refused);
      expect(await failureOf(http.Response('<html>Sign in</html>', 200, headers: {'content-type': 'text/html'})), Failure.refused);
      expect(await failureOf(FakeServer.json({}, 400)), Failure.rejected);
      expect(await failureOf(FakeServer.json({}, 413)), Failure.rejected);
      expect(await failureOf(FakeServer.json({}, 503)), Failure.offline);
      final api = RelayApi(connection, MockClient((_) => throw const SocketException('no signal')));
      await expectLater(api.timeline(), throwsA(isA<ApiException>().having((error) => error.failure, 'failure', Failure.offline)));
      expect(const ApiException(Failure.offline, 503).toString(), contains('503'));
    });
  });

  group('the store and outbox', () {
    late Store store;
    setUp(() => store = memoryStore());
    tearDown(() => store.close());

    final pin = Pin(at: at, lat: 43.65, lon: -79.38, accuracy: 12, place: 'King St W');
    LocalNote note(String id, {Pin? pin}) => LocalNote(clientId: id, text: 'Note $id', createdAt: DateTime.fromMillisecondsSinceEpoch(1793797200000), pin: pin);

    test('keeps a typed note as waiting until its upload lands, in order', () async {
      await store.addNote(note('note-0001', pin: pin));
      await store.addNote(note('note-0002'));
      expect([for (final waiting in await store.waitingNotes()) waiting.clientId], unorderedEquals(['note-0001', 'note-0002']));
      expect((await store.waitingNotes()).firstWhere((waiting) => waiting.clientId == 'note-0001').pin!.place, 'King St W');
      final server = FakeServer();
      final result = await flush(store, server.api(connection));
      expect([result.sent, result.dropped, result.failure], [2, 0, null]);
      expect([for (final request in server.requests) jsonDecode(request.body)['clientId']], ['note-0001', 'note-0002']);
      expect(jsonDecode(server.requests.first.body), containsPair('place', 'King St W'));
      expect(await store.waitingNotes(), isEmpty);
      expect(await store.waiting(), 0);
    });

    test('stops at the first upload that can not land, and keeps it and the rest', () async {
      await store.addNote(note('note-0001'));
      await store.addNote(note('note-0002'));
      for (final failure in [(503, Failure.offline), (401, Failure.refused)]) {
        final server = FakeServer((_) => FakeServer.json({}, failure.$1));
        final result = await flush(store, server.api(connection));
        expect([result.sent, result.failure, server.requests.length], [0, failure.$2, 1]);
        expect(await store.waiting(), 2);
      }
    });

    test('drops a body the server turns down, so it holds back nothing', () async {
      await store.addNote(note('note-0001'));
      await store.enqueue('health', {'samples': []});
      final server = FakeServer((request) => request.url.path.endsWith('notes') ? FakeServer.json({}, 400) : FakeServer.ok(request));
      final result = await flush(store, server.api(connection));
      expect([result.sent, result.dropped], [1, 1]);
      expect(await store.waiting(), 0);
    });

    test('sends location points once each, 500 to a batch, oldest first', () async {
      for (var i = 0; i < 1001; i++) {
        await store.addPoint(Pin(at: DateTime.fromMillisecondsSinceEpoch(1793797200000 + i * 1000), lat: 43.6, lon: -79.3, accuracy: 10));
      }
      await store.addPoint(Pin(at: at, lat: 1, lon: 1, accuracy: 1));
      await store.queuePoints();
      final batches = [for (final item in await store.outbox()) (item.body['points'] as List)];
      expect([for (final batch in batches) batch.length], [500, 500, 1]);
      expect((batches.first.first as Map)['at'], 1793797200000);
      expect((batches.first.first as Map).containsKey('place'), isFalse);
      await store.queuePoints();
      expect(await store.waiting(), 3);
    });

    test('keeps small values by name', () async {
      expect(await store.get('x'), isNull);
      await store.set('x', '1');
      await store.set('x', '2');
      expect(await store.get('x'), '2');
    });
  });
}


import 'dart:convert';

import 'package:drift/drift.dart';

/// A note typed on this phone, kept here until the server has it.
class LocalNote {
  const LocalNote({required this.clientId, required this.text, required this.createdAt, this.pin});

  final String clientId;
  final String text;
  final DateTime createdAt;
  final Pin? pin;

  Map<String, dynamic> toJson() => {
    'clientId': clientId, 'text': text, 'createdAt': createdAt.millisecondsSinceEpoch,
    if (pin != null) ...{'lat': pin!.lat, 'lon': pin!.lon, 'accuracy': pin!.accuracy, if (pin!.place != null) 'place': pin!.place},
  };
}

/// Where the phone was: for a note's pin, or one point of location history.
class Pin {
  const Pin({required this.at, required this.lat, required this.lon, required this.accuracy, this.place});

  final DateTime at;
  final double lat;
  final double lon;
  final double accuracy;
  final String? place;

  Map<String, dynamic> toJson() =>
    {'at': at.millisecondsSinceEpoch, 'lat': lat, 'lon': lon, 'accuracy': accuracy, if (place != null) 'place': place};
}

/// One waiting upload: a route and the JSON body to send it.
class OutboxItem {
  const OutboxItem(this.id, this.route, this.body);

  final int id;
  final String route;
  final Map<String, dynamic> body;
}

const _schema = [
  'CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, route TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL)',
  // queued = 0: the note waits for its pin and has no upload yet, so no sync can send it without its place.
  'CREATE TABLE notes (client_id TEXT PRIMARY KEY, body TEXT NOT NULL, created_at INTEGER NOT NULL, sent INTEGER NOT NULL DEFAULT 0, queued INTEGER NOT NULL DEFAULT 1)',
  'CREATE TABLE points (at INTEGER PRIMARY KEY, body TEXT NOT NULL)',
  'CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
];

/// The phone's own SQLite file: waiting uploads, its typed notes, location points not yet sent, and small settings.
/// Written as plain SQL through drift, so the app needs no generated code.
class Store extends GeneratedDatabase {
  Store(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {
    for (final statement in _schema) {
      await customStatement(statement);
    }
  }, onUpgrade: (_, from, to) async {
    // Version 1 queued every note as it was kept.
    if (from < 2) await customStatement('ALTER TABLE notes ADD COLUMN queued INTEGER NOT NULL DEFAULT 1');
  });

  Future<List<QueryRow>> _rows(String sql, [List<Object?> values = const []]) =>
    customSelect(sql, variables: [for (final value in values) Variable(value)]).get();

  Future<void> _run(String sql, [List<Object?> values = const []]) => customStatement(sql, values);

  Future<void> enqueue(String route, Map<String, dynamic> body) =>
    _run('INSERT INTO outbox (route, body, created_at) VALUES (?, ?, ?)', [route, jsonEncode(body), DateTime.now().millisecondsSinceEpoch]);

  /// Every waiting upload, oldest first.
  Future<List<OutboxItem>> outbox() async => [
    for (final row in await _rows('SELECT id, route, body FROM outbox ORDER BY id'))
      OutboxItem(row.read<int>('id'), row.read<String>('route'), jsonDecode(row.read<String>('body')) as Map<String, dynamic>),
  ];

  /// Waiting uploads, and notes that wait for their pin before they get one.
  Future<int> waiting() async => (await _rows(
    'SELECT (SELECT count(*) FROM outbox) + (SELECT count(*) FROM notes WHERE queued = 0 AND sent = 0) AS n')).single.read<int>('n');

  Future<void> done(int id) => _run('DELETE FROM outbox WHERE id = ?', [id]);

  /// Keeps the note and queues its upload together, so neither is ever left without the other. With [waitForPin]
  /// the note is kept and shown, but gets its upload only from [queueNote], so a sync meanwhile can not send it bare.
  Future<void> addNote(LocalNote note, {bool waitForPin = false}) => transaction(() async {
    final body = note.toJson();
    await _run('INSERT INTO notes (client_id, body, created_at, queued) VALUES (?, ?, ?, ?)',
      [note.clientId, jsonEncode(body), note.createdAt.millisecondsSinceEpoch, waitForPin ? 0 : 1]);
    if (!waitForPin) await enqueue('notes', body);
  });

  /// Queues a note that waited for its pin, with the pin when the phone found one: the note and its upload get the
  /// same body in one step. False when the note is not waiting, such as one queued already.
  Future<bool> queueNote(String clientId, Pin? pin) => transaction(() async {
    final notes = await _rows('SELECT body FROM notes WHERE client_id = ? AND queued = 0 AND sent = 0', [clientId]);
    if (notes.isEmpty) return false;
    final note = _noteOf(jsonDecode(notes.single.read<String>('body')) as Map<String, dynamic>);
    final body = LocalNote(clientId: clientId, text: note.text, createdAt: note.createdAt, pin: pin).toJson();
    await _run('UPDATE notes SET body = ?, queued = 1 WHERE client_id = ?', [jsonEncode(body), clientId]);
    await enqueue('notes', body);
    return true;
  });

  /// Queues, without a place, each note whose wait for a pin the app's close cut short.
  Future<void> queueWaiting() async {
    for (final row in await _rows('SELECT client_id FROM notes WHERE queued = 0 AND sent = 0 ORDER BY created_at')) {
      await queueNote(row.read<String>('client_id'), null);
    }
  }

  Future<void> noteSent(String clientId) => _run('UPDATE notes SET sent = 1 WHERE client_id = ?', [clientId]);

  /// Typed notes the server does not have yet, newest first.
  Future<List<LocalNote>> waitingNotes() async => [
    for (final row in await _rows('SELECT body FROM notes WHERE sent = 0 ORDER BY created_at DESC'))
      _noteOf(jsonDecode(row.read<String>('body')) as Map<String, dynamic>),
  ];

  static LocalNote _noteOf(Map<String, dynamic> body) => LocalNote(
    clientId: body['clientId'] as String, text: body['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(body['createdAt'] as int),
    pin: body['lat'] == null ? null : Pin(at: DateTime.fromMillisecondsSinceEpoch(body['createdAt'] as int),
      lat: (body['lat'] as num).toDouble(), lon: (body['lon'] as num).toDouble(),
      accuracy: (body['accuracy'] as num).toDouble(), place: body['place'] as String?),
  );

  /// One point of location history; a second at the same moment is the same point.
  Future<void> addPoint(Pin point) =>
    _run('INSERT OR IGNORE INTO points (at, body) VALUES (?, ?)', [point.at.millisecondsSinceEpoch, jsonEncode(point.toJson())]);

  /// Moves up to [batch] points at a time into the outbox, in time order.
  Future<void> queuePoints({int batch = 500}) => transaction(() async {
    while (true) {
      final rows = await _rows('SELECT at, body FROM points ORDER BY at LIMIT ?', [batch]);
      if (rows.isEmpty) return;
      await enqueue('locations', {'points': [for (final row in rows) jsonDecode(row.read<String>('body'))]});
      await _run('DELETE FROM points WHERE at <= ?', [rows.last.read<int>('at')]);
    }
  });

  Future<String?> get(String key) async {
    final rows = await _rows('SELECT value FROM state WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single.read<String>('value');
  }

  Future<void> set(String key, String value) => _run('INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)', [key, value]);
}

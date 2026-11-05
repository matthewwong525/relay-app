import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'data/api.dart';
import 'data/connection.dart';
import 'data/outbox.dart';
import 'data/store.dart';
import 'relay.dart';
import 'sync/health.dart';
import 'sync/location.dart';

const _settingsKey = 'settings', _cacheKey = 'timeline';

/// A random id for a typed note, so a resend is stored once.
String newClientId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(16, (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// The app's one Relay: the key in the vault, everything else in the store, and sync on open, on a new note,
/// on pull, and every hour in the background.
class RelayController extends Relay {
  RelayController({required this.store, required this.vault, required this.places, required this.health,
    RelayApi Function(Connection)? apiFor, DateTime Function()? clock, this.schedule})
    : _apiFor = apiFor ?? RelayApi.new, _clock = clock ?? DateTime.now;

  final Store store;
  final KeyVault vault;
  final Places places;
  final HealthSource health;
  /// Turns the hourly background sync on or off.
  final Future<void> Function(bool on)? schedule;
  final RelayApi Function(Connection) _apiFor;
  final DateTime Function() _clock;

  Connection? _connection;
  List<Entry> _server = const [];
  List<Entry> _local = const [];
  Cursor? _next;
  SyncStatus _status = SyncStatus.idle;
  int _waiting = 0;
  Settings _settings = const Settings();
  StreamSubscription<Pin>? _history;
  Future<void>? _syncing;

  @override bool get connected => _connection != null;
  @override String? get server => _connection?.server;
  @override List<Entry> get entries => [..._local, ..._server];
  @override bool get hasMore => _next != null;
  @override SyncStatus get status => _status;
  @override int get waiting => _waiting;
  @override Settings get settings => _settings;

  /// Reads the key, the settings and the last timeline seen, so the app opens with no network.
  Future<void> load() async {
    _connection = await vault.read();
    final saved = await store.get(_settingsKey);
    if (saved != null) {
      final json = jsonDecode(saved) as Map<String, dynamic>;
      _settings = Settings(pinNotes: json['pinNotes'] as bool, history: json['history'] as bool, health: json['health'] as bool);
    }
    final cache = await store.get(_cacheKey);
    if (cache != null) _server = [for (final note in jsonDecode(cache) as List) _entryOf(RemoteNote.fromJson(note as Map<String, dynamic>))];
    if (_settings.history) _startHistory();
    // Nothing waits for a fix yet at start, so a note still waiting lost its wait when the app closed.
    await store.queueWaiting();
    await _refreshLocal();
  }

  static Entry _entryOf(RemoteNote note) => Entry(text: note.text, ring: note.source == 'ring', at: note.recordedAt,
    place: note.place, device: note.device, audio: note.audio);

  Future<void> _refreshLocal() async {
    _local = [
      for (final note in await store.waitingNotes())
        Entry(text: note.text, ring: false, at: note.createdAt, place: note.pin?.place ?? _coordinates(note.pin), waiting: true),
    ];
    _waiting = await store.waiting();
    notifyListeners();
  }

  static String? _coordinates(Pin? pin) => pin == null ? null : '${pin.lat.toStringAsFixed(4)}, ${pin.lon.toStringAsFixed(4)}';

  @override
  Future<String?> connect(String code) async {
    final connection = Connection.parse(code);
    if (connection == null) return 'That is not a Relay key. Scan the QR code again, or paste all of it.';
    try {
      await _apiFor(connection).timeline();
    } on ApiException catch (error) {
      // With no signal the key is kept and tried on the next sync.
      if (error.failure != Failure.offline) return 'The server did not take this key. Make a new key and try again.';
    }
    await vault.save(connection);
    _connection = connection;
    // Pins start on, so the phone asks for location once here; a no keeps notes without a place.
    if (_settings.pinNotes) await places.allow(always: false);
    unawaited(sync());
    return null;
  }

  @override
  Future<String?> setServer(String text) async {
    final server = Connection.serverOf(text);
    if (server == null) return 'Enter an address that starts with https:// and has no path.';
    if (_connection == null) return 'Connect a key first.';
    _connection = _connection!.withServer(server);
    await vault.save(_connection!);
    notifyListeners();
    return null;
  }

  @override
  Future<void> disconnect() async {
    await vault.forget();
    await store.set(_cacheKey, '[]');
    _connection = null;
    _server = const [];
    _next = null;
    _status = SyncStatus.idle;
    notifyListeners();
  }

  Future<void> _saveSettings(Settings settings) async {
    _settings = settings;
    await store.set(_settingsKey, jsonEncode({'pinNotes': settings.pinNotes, 'history': settings.history, 'health': settings.health}));
    await schedule?.call(settings.history || settings.health);
    notifyListeners();
  }

  static const _noLocation = 'Relay may not read your location. Allow it in the phone\'s settings.';

  @override
  Future<String?> setPinNotes(bool on) async {
    if (on && !await places.allow(always: false)) return _noLocation;
    await _saveSettings(Settings(pinNotes: on, history: _settings.history, health: _settings.health));
    return null;
  }

  @override
  Future<String?> setHistory(bool on) async {
    if (on && !await places.allow(always: true)) return 'Relay may not read your location all the time. Allow it in the phone\'s settings.';
    await _saveSettings(Settings(pinNotes: _settings.pinNotes, history: on, health: _settings.health));
    if (on) {
      _startHistory();
    } else {
      await _history?.cancel();
      _history = null;
    }
    return null;
  }

  void _startHistory() {
    _history ??= places.history().listen((point) => store.addPoint(point), onError: (_) {});
  }

  @override
  Future<String?> setHealth(bool on) async {
    if (on && !await health.allow()) return 'Relay may not read your health data. Allow it in the phone\'s health settings.';
    await _saveSettings(Settings(pinNotes: _settings.pinNotes, history: _settings.history, health: on));
    if (on) unawaited(sync());
    return null;
  }

  /// Keeps and shows the note at once; Save never waits for a fix. With pins on, the note gets its upload only when
  /// the phone has a fix or gives up (up to 10 s), so a sync meanwhile sends the rest and leaves this note waiting.
  @override
  Future<void> addNote(String text) async {
    final note = LocalNote(clientId: newClientId(), text: text.trim(), createdAt: _clock());
    final pinned = _settings.pinNotes;
    await store.addNote(note, waitForPin: pinned);
    await _refreshLocal();
    unawaited(pinned ? _pinThenSync(note.clientId) : sync());
  }

  Future<void> _pinThenSync(String clientId) async {
    Pin? pin;
    try {
      pin = await places.here();
    } on Exception {
      // No fix: the note goes without a place.
    }
    await store.queueNote(clientId, pin);
    await _refreshLocal();
    await sync();
  }

  /// One sync at a time; a second call waits for the one running.
  @override
  Future<void> sync() => _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    final connection = _connection;
    if (connection == null) return;
    _status = SyncStatus.syncing;
    notifyListeners();
    if (_settings.health) {
      try {
        await syncHealth(store, health, now: _clock());
      } on Exception {
        // The health store can be closed for a while, such as on a locked iPhone; the next round reads again.
      }
    }
    await store.queuePoints();
    final api = _apiFor(connection);
    final result = await flush(store, api);
    _status = switch (result.failure) { Failure.refused => SyncStatus.refused, null => SyncStatus.synced, _ => SyncStatus.offline };
    if (result.failure == null) {
      try {
        final page = await api.timeline();
        _server = [for (final note in page.notes) _entryOf(note)];
        _next = page.next;
        await store.set(_cacheKey, jsonEncode([for (final note in page.notes) note.json]));
      } on ApiException catch (error) {
        _status = error.failure == Failure.refused ? SyncStatus.refused : SyncStatus.offline;
      }
    }
    await _refreshLocal();
  }

  @override
  Future<void> more() async {
    final connection = _connection, before = _next;
    if (connection == null || before == null) return;
    try {
      final page = await _apiFor(connection).timeline(before: before);
      _server = [..._server, for (final note in page.notes) _entryOf(note)];
      _next = page.next;
    } on ApiException {
      _status = SyncStatus.offline;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _history?.cancel();
    super.dispose();
  }
}

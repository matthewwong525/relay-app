import 'package:flutter/foundation.dart';

/// One row of the timeline: a note the server has, or one typed here that is still waiting to send.
class Entry {
  const Entry({required this.text, required this.ring, required this.at, this.place, this.device, this.waiting = false, this.audio = false});

  final String text;
  final bool ring;
  final DateTime at;
  final String? place;
  final String? device;
  final bool waiting;
  final bool audio;
}

enum SyncStatus { idle, syncing, synced, offline, refused }

/// What the person turned on. Each asks for its permission when turned on, and never before.
class Settings {
  const Settings({this.pinNotes = true, this.history = false, this.health = false});

  final bool pinNotes;
  final bool history;
  final bool health;
}

/// What the screens read and do. The app's controller is one; a test's fake is another.
abstract class Relay extends ChangeNotifier {
  bool get connected;
  String? get server;
  List<Entry> get entries;
  bool get hasMore;
  SyncStatus get status;
  int get waiting;
  Settings get settings;

  /// Each returns null on success, or the words to show when it failed.
  Future<String?> connect(String code);
  Future<String?> setServer(String server);
  Future<String?> setPinNotes(bool on);
  Future<String?> setHistory(bool on);
  Future<String?> setHealth(bool on);

  Future<void> disconnect();
  Future<void> sync();
  Future<void> more();
  Future<void> addNote(String text);
}

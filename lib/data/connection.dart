import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where this phone sends, and its own device key: a Cloudflare Access service token.
class Connection {
  const Connection({required this.server, required this.clientId, required this.clientSecret});

  final String server;
  final String clientId;
  final String clientSecret;

  Connection withServer(String server) => Connection(server: server, clientId: clientId, clientSecret: clientSecret);

  /// The code `relay-device-key.mjs create` shows as a QR code, scanned or pasted. Null when it is not one.
  static Connection? parse(String text) {
    try {
      final code = jsonDecode(text.trim());
      if (code is! Map || code['relay'] != 1) return null;
      final server = serverOf(code['server']);
      final id = code['clientId'], secret = code['clientSecret'];
      if (server == null || id is! String || secret is! String || id.isEmpty || secret.isEmpty) return null;
      return Connection(server: server, clientId: id, clientSecret: secret);
    } on FormatException {
      return null;
    }
  }

  /// An https address with no path, as the app sends to; null for anything else.
  static String? serverOf(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || (uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery) return null;
    return uri.origin;
  }
}

/// The key's home: the Keychain on iPhone and the Keystore on Android, never the app's database.
class KeyVault {
  KeyVault([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _server = 'relay.server', _id = 'relay.clientId', _secret = 'relay.clientSecret';

  Future<Connection?> read() async {
    final values = await _storage.readAll();
    final server = values[_server], id = values[_id], secret = values[_secret];
    if (server == null || id == null || secret == null) return null;
    return Connection(server: server, clientId: id, clientSecret: secret);
  }

  Future<void> save(Connection connection) async {
    await _storage.write(key: _server, value: connection.server);
    await _storage.write(key: _id, value: connection.clientId);
    await _storage.write(key: _secret, value: connection.clientSecret);
  }

  Future<void> forget() async {
    for (final key in [_server, _id, _secret]) {
      await _storage.delete(key: key);
    }
  }
}

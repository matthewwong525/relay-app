import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connection.dart';

/// Why a call did not land: the key was refused, the server turned the body down, or the network or server failed.
enum Failure { refused, rejected, offline }

class ApiException implements Exception {
  const ApiException(this.failure, this.status);

  final Failure failure;
  final int? status;

  @override
  String toString() => 'ApiException($failure, $status)';
}

/// One note as the server's timeline gives it.
class RemoteNote {
  const RemoteNote({required this.id, required this.source, required this.text, required this.recordedAt,
    required this.device, required this.audio, this.place, this.json = const {}});

  final String id;
  final String source;
  final String text;
  final DateTime recordedAt;
  final String device;
  final bool audio;
  final String? place;

  /// The server's own words for this note, kept so the timeline cache reads back the same.
  final Map<String, dynamic> json;

  factory RemoteNote.fromJson(Map<String, dynamic> json) {
    final place = json['place'] as Map<String, dynamic>?;
    return RemoteNote(
      id: json['id'] as String, source: json['source'] as String, text: json['text'] as String,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(json['recordedAt'] as int), device: json['device'] as String,
      audio: json['audio'] as bool,
      place: place == null ? null : (place['name'] as String?) ??
        '${(place['lat'] as num).toStringAsFixed(4)}, ${(place['lon'] as num).toStringAsFixed(4)}',
      json: json,
    );
  }
}

/// Where the timeline's next page starts: the last note's time and id, as two notes can share a time.
typedef Cursor = ({int at, String? id});

/// Relay's device routes, each call carrying this phone's key in Cloudflare Access's two headers.
class RelayApi {
  RelayApi(this.connection, [http.Client? client]) : _client = client ?? http.Client();

  final Connection connection;
  final http.Client _client;
  static const _timeout = Duration(seconds: 30);

  Uri _uri(String route, [Map<String, String>? query]) =>
    Uri.parse('${connection.server}/apps/relay/api/$route').replace(queryParameters: query);

  Map<String, String> get _headers =>
    {'CF-Access-Client-Id': connection.clientId, 'CF-Access-Client-Secret': connection.clientSecret, 'Accept': 'application/json'};

  /// Sends one JSON body to a POST route and returns its answer.
  Future<Map<String, dynamic>> post(String route, Map<String, dynamic> body) =>
    _call(() => _client.post(_uri(route), headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)));

  /// The newest notes, or those after [before] in the timeline's order.
  Future<({List<RemoteNote> notes, Cursor? next})> timeline({Cursor? before}) async {
    final query = before == null ? null : {'before': '${before.at}', if (before.id != null) 'beforeId': before.id!};
    final json = await _call(() => _client.get(_uri('timeline', query), headers: _headers));
    final next = json['next'] as int?;
    return (
      notes: [for (final note in json['notes'] as List) RemoteNote.fromJson(note as Map<String, dynamic>)],
      next: next == null ? null : (at: next, id: json['nextId'] as String?),
    );
  }

  Future<Map<String, dynamic>> _call(Future<http.Response> Function() send) async {
    final http.Response response;
    try {
      response = await send().timeout(_timeout);
    } on Exception {
      throw const ApiException(Failure.offline, null);
    }
    final status = response.statusCode;
    // Cloudflare Access answers a refused key with its sign-in page, a redirect or HTML, never JSON.
    final json = response.headers['content-type']?.startsWith('application/json') ?? false;
    if (status == 401 || status == 403 || (status >= 300 && status < 400) || (status == 200 && !json)) {
      throw ApiException(Failure.refused, status);
    }
    if (status == 400 || status == 413) throw ApiException(Failure.rejected, status);
    if (status != 200) throw ApiException(Failure.offline, status);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

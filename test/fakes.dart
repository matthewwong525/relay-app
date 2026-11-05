import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_app/data/api.dart';
import 'package:relay_app/data/connection.dart';
import 'package:relay_app/data/store.dart';
import 'package:relay_app/sync/health.dart';
import 'package:relay_app/sync/location.dart';

const connection = Connection(server: 'https://relay.example.com', clientId: 'phone.access', clientSecret: 'secret-value');
final code = jsonEncode({'relay': 1, 'server': connection.server, 'clientId': connection.clientId, 'clientSecret': connection.clientSecret});

Store memoryStore() => Store(NativeDatabase.memory());

/// A server answering each route with [answer]; every request it saw is kept.
class FakeServer {
  FakeServer([http.Response Function(http.Request request)? answer]) : answer = answer ?? ok;

  http.Response Function(http.Request request) answer;
  final requests = <http.Request>[];

  static http.Response ok(http.Request request) => json(request.url.path.endsWith('/timeline') ? {'notes': [], 'next': null} : {'added': 1});
  static http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  RelayApi api(Connection connection) => RelayApi(connection, MockClient((request) async {
    requests.add(request);
    return answer(request);
  }));

  List<String> get routes => [for (final request in requests) request.url.path.split('/').last];
}

class MemoryStorage extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<Map<String, String>> readAll({AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
    WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async => Map.of(values);

  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions, AndroidOptions? aOptions,
    LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async => values[key] = value!;

  @override
  Future<void> delete({required String key, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
    WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async => values.remove(key);
}

class FakePlaces implements Places {
  bool allowed = true;
  Pin? pin;
  /// When set, a note's fix waits for it, as a real fix can take seconds.
  Completer<Pin?>? fix;
  /// Each ask for location, by whether it was for all the time.
  final asked = <bool>[];
  final points = StreamController<Pin>.broadcast();

  @override
  Future<bool> allow({required bool always}) async {
    asked.add(always);
    return allowed;
  }

  @override
  Future<Pin?> here() async => fix == null ? pin : fix!.future;

  @override
  Stream<Pin> history() => points.stream;
}

class FakeHealth implements HealthSource {
  bool allowed = true;
  List<HealthDataPoint> readings = [];
  Object? error;
  final reads = <(DateTime, DateTime)>[];

  @override
  Future<bool> allow() async => allowed;

  @override
  Future<List<HealthDataPoint>> read(DateTime from, DateTime to) async {
    reads.add((from, to));
    if (error != null) throw error!;
    return readings;
  }
}

HealthDataPoint reading(HealthDataType type, DateTime from, DateTime to, {num value = 0, String sourceId = 'com.apple.health'}) =>
  HealthDataPoint(
    uuid: '${type.name}-${from.millisecondsSinceEpoch}', type: type, unit: HealthDataUnit.COUNT, dateFrom: from, dateTo: to,
    value: type == HealthDataType.WORKOUT
      ? WorkoutHealthValue(workoutActivityType: HealthWorkoutActivityType.RUNNING)
      : NumericHealthValue(numericValue: value),
    sourcePlatform: HealthPlatformType.appleHealth, sourceDeviceId: 'device', sourceId: sourceId, sourceName: 'Health',
  );

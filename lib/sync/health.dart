import 'dart:io';

import 'package:health/health.dart';

import '../data/store.dart';

/// The health types Relay keeps, by the server's names. iPhone splits sleep by stage; Android has whole sessions.
final Map<HealthDataType, String> kinds = {
  HealthDataType.STEPS: 'steps',
  HealthDataType.HEART_RATE: 'heart_rate',
  HealthDataType.WORKOUT: 'workout',
  if (Platform.isAndroid) HealthDataType.SLEEP_SESSION: 'sleep'
  else ...{HealthDataType.SLEEP_ASLEEP: 'sleep', HealthDataType.SLEEP_LIGHT: 'sleep', HealthDataType.SLEEP_DEEP: 'sleep',
    HealthDataType.SLEEP_REM: 'sleep'},
};

const _units = {'steps': 'count', 'heart_rate': 'bpm', 'sleep': 'min', 'workout': 'min'};

/// One reading as the server's `health` route takes it, or null for a type Relay does not keep.
Map<String, dynamic>? sampleOf(HealthDataPoint point) {
  final kind = kinds[point.type];
  if (kind == null) return null;
  final minutes = point.dateTo.difference(point.dateFrom).inSeconds / 60;
  final value = point.value;
  final amount = kind == 'sleep' || kind == 'workout' ? minutes : value is NumericHealthValue ? value.numericValue.toDouble() : null;
  if (amount == null || amount < 0) return null;
  final source = point.sourceId.isNotEmpty ? point.sourceId : point.sourceName;
  return {
    'type': kind, 'start': point.dateFrom.millisecondsSinceEpoch, 'end': point.dateTo.millisecondsSinceEpoch,
    'value': amount, 'unit': _units[kind], 'source': source.isEmpty ? 'unknown' : source.substring(0, source.length.clamp(0, 200)),
  };
}

/// Where readings come from: the phone's health store, or a test's list.
abstract class HealthSource {
  Future<bool> allow();
  Future<List<HealthDataPoint>> read(DateTime from, DateTime to);
}

class PhoneHealth implements HealthSource {
  final _health = Health();

  @override
  Future<bool> allow() async {
    await _health.configure();
    final types = kinds.keys.toList();
    final allowed = await _health.requestAuthorization(types, permissions: [for (final _ in types) HealthDataAccess.READ]);
    // The hourly sync reads with no screen open, which Health Connect allows only with this second permission.
    if (allowed && Platform.isAndroid && await _health.isHealthDataInBackgroundAvailable()) {
      await _health.requestHealthDataInBackgroundAuthorization();
    }
    return allowed;
  }

  @override
  Future<List<HealthDataPoint>> read(DateTime from, DateTime to) async {
    await _health.configure();
    return _health.getHealthDataFromTypes(types: kinds.keys.toList(), startTime: from, endTime: to);
  }
}

const healthSince = 'health.since';
// Each round reads again a little before the last, so a reading the store saved late is not missed; the server keeps
// each once.
const _overlap = Duration(hours: 2);
const _firstRead = Duration(days: 7);

/// Reads every reading since the last round and queues them, 500 to a batch. Returns how many it queued.
Future<int> syncHealth(Store store, HealthSource source, {DateTime? now}) async {
  final to = now ?? DateTime.now();
  final saved = await store.get(healthSince);
  final from = saved == null ? to.subtract(_firstRead) : DateTime.fromMillisecondsSinceEpoch(int.parse(saved)).subtract(_overlap);
  final seen = <String>{};
  final samples = [
    for (final point in await source.read(from, to))
      if (sampleOf(point) case final sample? when seen.add('${sample['type']} ${sample['start']} ${sample['end']} ${sample['source']}')) sample,
  ];
  for (var at = 0; at < samples.length; at += 500) {
    await store.enqueue('health', {'samples': samples.sublist(at, (at + 500).clamp(0, samples.length))});
  }
  await store.set(healthSince, '${to.millisecondsSinceEpoch}');
  return samples.length;
}

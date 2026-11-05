import 'dart:async';
import 'dart:io';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../data/store.dart';

/// A short place name, as a person would say it: the street first, then the area.
String? placeOf(Placemark mark) {
  for (final part in [mark.thoroughfare, mark.street, mark.subLocality, mark.locality, mark.name]) {
    final name = part?.trim() ?? '';
    if (name.isNotEmpty) return name.length > 200 ? name.substring(0, 200) : name;
  }
  return null;
}

Pin pinOf(Position position, String? place) => Pin(
  at: position.timestamp, lat: position.latitude, lon: position.longitude,
  accuracy: position.accuracy.isFinite && position.accuracy >= 0 ? position.accuracy : 0, place: place);

/// Where the phone is: once for a note, and as it moves for the history.
abstract class Places {
  /// Asks for location, [always] for the background history. True when it may be read.
  Future<bool> allow({required bool always});
  Future<Pin?> here();
  Stream<Pin> history();
}

class PhonePlaces implements Places {
  final _geocoding = Geocoding();

  @override
  Future<bool> allow({required bool always}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    // iPhone asks for Always only after While Using is given, so a second request upgrades it.
    if (always && permission == LocationPermission.whileInUse && Platform.isIOS) permission = await Geolocator.requestPermission();
    return always ? permission == LocationPermission.always || (Platform.isAndroid && permission == LocationPermission.whileInUse)
      : permission == LocationPermission.always || permission == LocationPermission.whileInUse;
  }

  Future<String?> _name(Position position) async {
    try {
      final marks = await _geocoding.placemarkFromCoordinates(position.latitude, position.longitude);
      return marks.isEmpty ? null : placeOf(marks.first);
    } on Exception {
      return null;
    }
  }

  @override
  Future<Pin?> here() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)));
      return pinOf(position, await _name(position));
    } on Exception {
      // No fix in time, or no permission: the note is kept without a place.
      return null;
    }
  }

  @override
  Stream<Pin> history() {
    // A point every 100 m of movement, not constant GPS: it keeps battery use low.
    final LocationSettings settings = Platform.isAndroid
      ? AndroidSettings(accuracy: LocationAccuracy.medium, distanceFilter: 100, foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Relay is keeping your places', notificationText: 'Turn this off in Relay settings.', setOngoing: true))
      : AppleSettings(accuracy: LocationAccuracy.medium, distanceFilter: 100, activityType: ActivityType.other,
          pauseLocationUpdatesAutomatically: true, allowBackgroundLocationUpdates: true, showBackgroundLocationIndicator: false);
    return Geolocator.getPositionStream(locationSettings: settings).asyncMap((position) async => pinOf(position, await _name(position)));
  }
}

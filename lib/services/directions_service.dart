import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteResult {
  final double distanceKm; // total distance in kilometers
  final double durationSec; // total duration in seconds (estimated if fallback)
  final List<LatLng> points; // decoded polyline for flutter_map
  final bool fromFallback; // true if OSRM failed and we used Haversine

  const RouteResult({
    required this.distanceKm,
    required this.durationSec,
    required this.points,
    required this.fromFallback,
  });

  @override
  String toString() =>
      'RouteResult(km=${distanceKm.toStringAsFixed(2)}, sec=${durationSec.toStringAsFixed(0)}, pts=${points.length}, fb=$fromFallback)';
}

class DirectionsService {
  DirectionsService._();

  /// Base URL for OSRM. You can point this at your own OSRM server for reliability.
  /// e.g., 'https://your-osrm-host/route/v1'
  static String osrmBase = 'https://router.project-osrm.org/route/v1';

  /// Network timeout for OSRM HTTP call.
  static Duration timeout = const Duration(seconds: 12);

  /// Request a route polyline between [origin] and [destination].
  ///
  /// [profile] can be 'driving', 'walking', or 'cycling' (OSRM standard profiles).
  /// [preferPolyline6] fetches compact `polyline6` instead of GeoJSON to reduce payload.
  /// If OSRM fails, we fall back to straight-line with [fallbackAvgSpeedKph] to estimate duration.
  static Future<RouteResult> routePolyline({
    required LatLng origin,
    required LatLng destination,
    String profile = 'driving',
    bool preferPolyline6 = true,
    double fallbackAvgSpeedKph = 30.0,
  }) async {
    try {
      final rr = await _routeWithOSRM(
        origin: origin,
        destination: destination,
        profile: profile,
        preferPolyline6: preferPolyline6,
      );
      return rr;
    } catch (e) {
      // Fallback to straight line (Haversine)
      final distanceKm = _haversineKm(origin, destination);
      // Avoid zero duration: clamp to at least 60s
      final durationSec = math.max(
        60.0,
        (distanceKm / fallbackAvgSpeedKph) * 3600,
      );
      final points = <LatLng>[origin, destination];
      return RouteResult(
        distanceKm: distanceKm > 0 ? distanceKm : 1.0, // guard tiny values
        durationSec: durationSec,
        points: points,
        fromFallback: true,
      );
    }
  }

  /// OSRM implementation. Throws on failure.
  static Future<RouteResult> _routeWithOSRM({
    required LatLng origin,
    required LatLng destination,
    required String profile,
    required bool preferPolyline6,
  }) async {
    // OSRM expects "lng,lat;lng,lat"
    final coords =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';

    final geometries = preferPolyline6 ? 'polyline6' : 'geojson';
    final url =
        '$osrmBase/$profile/$coords?overview=full&alternatives=false&steps=false&geometries=$geometries';

    final res = await http.get(Uri.parse(url)).timeout(timeout);
    if (res.statusCode != 200) {
      throw Exception('OSRM HTTP ${res.statusCode}');
    }

    final data = json.decode(res.body) as Map<String, dynamic>;
    if (data['code'] != 'Ok' ||
        data['routes'] == null ||
        (data['routes'] as List).isEmpty) {
      throw Exception('OSRM returned no route');
    }

    final route = (data['routes'] as List).first as Map<String, dynamic>;
    final distMeters = (route['distance'] as num).toDouble();
    final durationSec = (route['duration'] as num).toDouble();

    // Decode geometry
    List<LatLng> points;
    if (preferPolyline6) {
      final poly = route['geometry'] as String?; // polyline6
      if (poly == null || poly.isEmpty) {
        throw Exception('OSRM missing polyline');
      }
      points = _decodePolyline(poly, precisionExponent: 6);
    } else {
      final geom = route['geometry'] as Map<String, dynamic>?;
      if (geom == null || geom['coordinates'] == null) {
        throw Exception('OSRM missing geojson');
      }
      points = (geom['coordinates'] as List)
          .cast<List>()
          .map(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          )
          .toList();
    }

    return RouteResult(
      distanceKm: distMeters / 1000.0,
      durationSec: durationSec,
      points: points,
      fromFallback: false,
    );
  }

  /// Google/OSRM polyline decoder.
  /// Set [precisionExponent] to 5 for standard "polyline5", 6 for OSRM "polyline6".
  static List<LatLng> _decodePolyline(
    String encoded, {
    int precisionExponent = 5,
  }) {
    final List<LatLng> points = [];
    int index = 0, lat = 0, lng = 0;
    final len = encoded.length;
    final factor = math.pow(10, precisionExponent).toDouble();

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / factor, lng / factor));
    }
    return points;
  }

  /// Haversine distance (kilometers).
  static double _haversineKm(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);

    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadiusKm * c;
  }

  static double _deg2rad(double deg) => deg * math.pi / 180.0;
}

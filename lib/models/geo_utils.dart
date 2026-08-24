import 'dart:math' as math;

/// Haversine distance in kilometers.
double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0; // km
  double d2r(double d) => d * math.pi / 180.0;

  final dLat = d2r(lat2 - lat1);
  final dLon = d2r(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(d2r(lat1)) *
          math.cos(d2r(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}

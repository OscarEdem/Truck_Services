// lib/services/estimation_service.dart
import 'dart:math' as math;

/// Vehicle types your UI uses
enum VehicleType { bike, van, truck }

/// Result from the fare estimator
class FareQuote {
  final double distanceKm; // computed straight-line fallback
  final int timeMin; // rough ETA guess
  final int priceCents; // total price (in pesewas)
  final Map<String, int> breakdownCents; // base, distance, surge, etc.

  const FareQuote({
    required this.distanceKm,
    required this.timeMin,
    required this.priceCents,
    required this.breakdownCents,
  });

  String formatGHS() => 'GH₵ ${(priceCents / 100).toStringAsFixed(2)}';
}

/// Estimator supports simple Haversine fallback (no external API).
/// If you later plug Google/OSM Distance Matrix, feed real km/min into `estimate`.
class EstimationService {
  // Base config (tune to Ghana market)
  static const _baseCents = {
    VehicleType.bike: 1500, // GH₵ 15.00 base
    VehicleType.van: 3000, // GH₵ 30.00
    VehicleType.truck: 8000, // GH₵ 80.00
  };

  static const _perKmCents = {
    VehicleType.bike: 400, // GH₵ 4.00 / km
    VehicleType.van: 700, // GH₵ 7.00 / km
    VehicleType.truck: 1200, // GH₵ 12.00 / km
  };

  static const _minFareCents = {
    VehicleType.bike: 1800, // GH₵ 18.00 minimum
    VehicleType.van: 3500,
    VehicleType.truck: 8000,
  };

  /// Optional surge logic (e.g., heavy rain, peak hour). Keep 1.0 if none.
  static double surgeMultiplierFor(DateTime when) {
    // Peak 7–9am / 4–7pm
    final h = when.hour;
    final peak = (h >= 7 && h < 9) || (h >= 16 && h < 19);
    return peak ? 1.15 : 1.0;
  }

  /// Haversine straight-line km. Use as fallback when no routing API.
  static double haversineKm(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const r = 6371.0;
    double dLat = _deg2rad(lat2 - lat1);
    double dLon = _deg2rad(lng2 - lng1);
    double a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _deg2rad(double d) => d * math.pi / 180.0;

  /// Estimate using fallback distance & a simple avg speed (km/h) → ETA.
  static FareQuote estimate({
    required VehicleType vehicle,
    required double pickupLat,
    required double pickupLng,
    required double dropLat,
    required double dropLng,
    DateTime? at,
    double? distanceKmOverride, // if you have Distance Matrix
    int? etaMinOverride, // if you have routing ETA
  }) {
    final now = at ?? DateTime.now();
    final distKm =
        (distanceKmOverride ??
                haversineKm(pickupLat, pickupLng, dropLat, dropLng))
            .clamp(0.0, 9999.0);

    // Rough ETA via average speed by vehicle
    final avgKph = switch (vehicle) {
      VehicleType.bike => 28.0,
      VehicleType.van => 25.0,
      VehicleType.truck => 22.0,
    };
    final etaMin =
        etaMinOverride ?? math.max(7, (distKm / avgKph * 60).round());

    // Pricing
    final base = _baseCents[vehicle]!;
    final perKm = _perKmCents[vehicle]!;
    final minFare = _minFareCents[vehicle]!;

    // Charge at least 1.5 km for very short hops
    final billableKm = math.max(1.5, distKm);
    final raw = base + (billableKm * perKm).round();

    final surgeMult = surgeMultiplierFor(now);
    final surged = (raw * surgeMult).round();

    final total = math.max(minFare, surged);

    return FareQuote(
      distanceKm: distKm,
      timeMin: etaMin,
      priceCents: total,
      breakdownCents: {
        'base': base,
        'distance': (billableKm * perKm).round(),
        if (surgeMult > 1.0) 'surge_added': (surged - raw),
        'min_adjust': total > surged ? (total - surged) : 0,
      },
    );
  }
}

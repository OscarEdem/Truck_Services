import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/delivery.dart';
import '../models/driver.dart';
import '../models/driver_location.dart';
import '../models/geo_utils.dart';

class AssignmentViewModel extends ChangeNotifier {
  final FirebaseFirestore _db;
  AssignmentViewModel({FirebaseFirestore? db})
    : _db = db ?? FirebaseFirestore.instance;

  /// Find nearest eligible driver & assign atomically.
  Future<bool> retryAssign(
    String deliveryId, {
    int maxCandidates = 200,
    Duration locationFreshWithin = const Duration(minutes: 10),
    double? maxDistanceKm,
    bool matchVehicleType = false,
  }) async {
    // 1) Load delivery
    final delRef = _db.collection('deliveries').doc(deliveryId);
    final delSnap = await delRef.get();
    if (!delSnap.exists) throw Exception('Delivery not found');

    final delivery = Delivery.fromDoc(delSnap);

    // Only assign pending + unassigned
    if (delivery.status != 'pending' || delivery.driverId != null) {
      return false;
    }

    // 2) Fetch recent driver locations
    final freshCutoff = Timestamp.fromDate(
      DateTime.now().subtract(locationFreshWithin),
    );

    final locSnap = await _db
        .collection('driver_locations')
        .where('updated_at', isGreaterThan: freshCutoff)
        .orderBy('updated_at', descending: true)
        .limit(maxCandidates)
        .get();

    if (locSnap.docs.isEmpty) return false;

    final locations = locSnap.docs
        .map((d) => DriverLocation.fromDoc(d))
        .toList();

    // 3) Load driver profiles (batched whereIn, max 10 per query)
    final driverIds = locations.map((e) => e.driverId).toSet().toList();
    final List<Driver> drivers = [];

    const chunk = 10;
    for (var i = 0; i < driverIds.length; i += chunk) {
      final idsChunk = driverIds.sublist(
        i,
        (i + chunk > driverIds.length) ? driverIds.length : i + chunk,
      );
      final profSnap = await _db
          .collection('profiles')
          .where(FieldPath.documentId, whereIn: idsChunk)
          .get();
      drivers.addAll(profSnap.docs.map((d) => Driver.fromDoc(d)));
    }

    // 4) Score candidates by distance (and optional vehicle match)
    final List<_Candidate> candidates = [];
    final now = Timestamp.now();

    for (final loc in locations) {
      final driver = drivers.firstWhere(
        (p) => p.uid == loc.driverId,
        orElse: () => Driver(uid: loc.driverId, isOnline: false),
      );
      if (!driver.isOnline) continue;

      if (matchVehicleType) {
        final dVeh = (driver.vehicleType ?? '').trim();
        if (dVeh.isEmpty || dVeh != delivery.vehicleType) continue;
      }

      final distKm = haversineKm(
        delivery.pickupLat,
        delivery.pickupLng,
        loc.lat,
        loc.lng,
      );
      if (maxDistanceKm != null && distKm > maxDistanceKm) continue;

      candidates.add(
        _Candidate(
          driverId: driver.uid,
          distanceKm: distKm,
          updatedAt: loc.updatedAt ?? now,
        ),
      );
    }

    if (candidates.isEmpty) return false;

    candidates.sort((a, b) {
      final byDist = a.distanceKm.compareTo(b.distanceKm);
      if (byDist != 0) return byDist;
      return b.updatedAt.millisecondsSinceEpoch -
          a.updatedAt.millisecondsSinceEpoch;
    });

    final chosen = candidates.first;

    // 5) Atomic assign if still pending & unassigned
    final success = await _db.runTransaction((tx) async {
      final fresh = await tx.get(delRef);
      if (!fresh.exists) return false;
      final data = fresh.data() as Map<String, dynamic>;

      final status = (data['status'] as String?) ?? 'pending';
      final currentDriver = data['driver_id'];
      final unassigned =
          currentDriver == null ||
          (currentDriver is String && currentDriver.isEmpty);

      if (status == 'pending' && unassigned) {
        tx.update(delRef, {
          'driver_id': chosen.driverId,
          'status': 'accepted', // or 'assigned'
          'accepted_at': FieldValue.serverTimestamp(),
          'assignment_strategy': 'client_nearest',
        });
        return true;
      }
      return false;
    });

    return success;
  }
}

class _Candidate {
  final String driverId;
  final double distanceKm;
  final Timestamp updatedAt;

  _Candidate({
    required this.driverId,
    required this.distanceKm,
    required this.updatedAt,
  });
}

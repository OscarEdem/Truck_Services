// lib/viewmodel/delivery_view_model.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart'; // ChangeNotifier + BuildContext
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../models/delivery.dart';
import '../services/directions_service.dart';
import '../services/payment_service.dart'; // CargomatePaystack, PayResult

class DeliveryViewModel extends ChangeNotifier {
  // form
  String pickupAddress = '';
  String dropAddress = '';
  ll.LatLng? pickupPos;
  ll.LatLng? dropPos;
  String vehicleType = 'bike';

  // computed
  double distanceKm = 0;
  List<ll.LatLng> polyline = const [];
  bool usedFallback = false;

  // ui state
  bool busy = false;

  // ── helpers ────────────────────────────────────────────────────────────────
  double _deg2rad(double deg) => deg * math.pi / 180.0;

  double _haversineKm(ll.LatLng a, ll.LatLng b) {
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

  // Pricing (align with booking screen: base/km + booking fee with min fare)
  int computePrice(double km, String type) {
    final basePerKm = switch (type) {
      'truck' => 15.0,
      'van' => 8.0,
      _ => 5.0, // bike
    };
    const bookingFee = 3.0;
    final minFare = switch (type) {
      'truck' => 60.0,
      'van' => 25.0,
      _ => 15.0, // bike
    };

    final raw = km * basePerKm + bookingFee;
    final price = raw < minFare ? minFare : raw;
    return price.round();
  }

  // ── public actions ─────────────────────────────────────────────────────────
  void setPickup(String address, ll.LatLng pos) {
    pickupAddress = address.trim();
    pickupPos = pos;
    notifyListeners();
  }

  void setDrop(String address, ll.LatLng pos) {
    dropAddress = address.trim();
    dropPos = pos;
    notifyListeners();
  }

  void setVehicle(String v) {
    vehicleType = v;
    notifyListeners();
  }

  Future<bool> computeRouteAndPrice() async {
    if (pickupPos == null || dropPos == null) return false;

    busy = true;
    notifyListeners();
    try {
      usedFallback = false;
      try {
        final dir = await DirectionsService.routePolyline(
          origin: pickupPos!,
          destination: dropPos!,
          profile: 'driving',
          preferPolyline6: true,
          fallbackAvgSpeedKph: 30.0,
        );
        distanceKm = dir.distanceKm > 0 ? dir.distanceKm : 1.0;
        polyline = dir.points; // List<ll.LatLng>
        usedFallback = dir.fromFallback;
      } catch (_) {
        usedFallback = true;
        distanceKm = _haversineKm(pickupPos!, dropPos!);
        if (distanceKm <= 0) distanceKm = 1.0;
        polyline = <ll.LatLng>[pickupPos!, dropPos!];
      }
      return true;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Delivery draftToDelivery({required String senderId}) {
    final price = computePrice(distanceKm, vehicleType);
    return Delivery(
      senderId: senderId,
      pickupAddress: pickupAddress,
      dropAddress: dropAddress,
      pickupLat: pickupPos!.latitude,
      pickupLng: pickupPos!.longitude,
      dropLat: dropPos!.latitude,
      dropLng: dropPos!.longitude,
      vehicleType: vehicleType,
      distanceKm: distanceKm,
      price: price,
      status: 'pending',
      paid: false,
      usedFallback: usedFallback,
      createdAt: DateTime.now().toUtc(),
    );
  }

  /// New flow:
  /// 1) charge → get reference (PayResult)
  /// 2) verifyDelivery(reference, draftMap) → server creates/updates Firestore
  /// 3) return Delivery with id from server and paid=true
  Future<Delivery?> payAndCreateWithContext(BuildContext ctx) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    if (pickupPos == null || dropPos == null) {
      throw Exception('Missing locations');
    }

    final draft = draftToDelivery(senderId: user.uid);

    busy = true;
    notifyListeners();
    try {
      // Step 1: init + open checkout (hosted), get reference
      final payRes = await CargomatePaystack.charge(
        context: ctx,
        amount: draft.price.toDouble(),
        currency: 'GHS',
        // optional metadata for dashboard/debugging
        metadata: {
          'userId': user.uid,
          'pickup': pickupAddress,
          'drop': dropAddress,
          'vehicle': vehicleType,
          'price': draft.price,
        },
      );

      if (!payRes.ok || payRes.reference == null) {
        // user cancelled or failed to launch checkout
        return null;
      }

      // Step 2: ask server to verify & create the Firestore doc.
      final verify = await CargomatePaystack.verifyDelivery(
        reference: payRes.reference!,
        deliveryDraft: {
          // send what the server needs to build the document
          'sender_id': user.uid,
          'pickup_address': draft.pickupAddress,
          'drop_address': draft.dropAddress,
          'pickup_lat': draft.pickupLat,
          'pickup_lng': draft.pickupLng,
          'drop_lat': draft.dropLat,
          'drop_lng': draft.dropLng,
          'vehicle_type': draft.vehicleType,
          'distance_km': draft.distanceKm,
          'price': draft.price,
          'status': 'pending',
          'paid': true,
          'used_fallback': draft.usedFallback,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      );

      if (!verify.ok) {
        throw Exception('Verify failed: ${verify.error ?? 'unknown error'}');
      }

      final deliveryMap = verify.delivery ?? <String, dynamic>{};
      final newId =
          deliveryMap['id'] as String?; // may be null if server omitted

      // If you have Delivery.fromMap, use it here. Otherwise compose via copyWith:
      return draft.copyWith(id: newId, paid: true, status: 'pending');
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

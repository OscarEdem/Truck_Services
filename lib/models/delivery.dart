import 'package:cloud_firestore/cloud_firestore.dart';

class Delivery {
  final String? id;
  final String senderId;

  // NEW: assignment
  final String? driverId;

  // addresses
  final String pickupAddress;
  final String dropAddress;

  // coords (non-nullable in our app)
  final double pickupLat;
  final double pickupLng;
  final double dropLat;
  final double dropLng;

  // misc
  final String vehicleType; // bike | van | truck
  final double distanceKm;
  final int price; // GHS
  final String
  status; // pending | assigned | accepted | en_route | delivered | cancelled
  final bool paid;
  final bool usedFallback;

  final DateTime? createdAt;

  Delivery({
    this.id,
    required this.senderId,
    this.driverId, // ← NEW
    required this.pickupAddress,
    required this.dropAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropLat,
    required this.dropLng,
    required this.vehicleType,
    required this.distanceKm,
    required this.price,
    this.status = 'pending',
    this.paid = false,
    this.usedFallback = false,
    this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'sender_id': senderId,
    'driver_id': driverId, // ← NEW
    'pickup_address': pickupAddress,
    'drop_address': dropAddress,
    'pickup_lat': pickupLat,
    'pickup_lng': pickupLng,
    'drop_lat': dropLat,
    'drop_lng': dropLng,
    'vehicle_type': vehicleType,
    'distance_km': distanceKm,
    'price': price,
    'status': status,
    'paid': paid,
    'used_fallback': usedFallback,
    'created_at': createdAt != null
        ? Timestamp.fromDate(createdAt!)
        : FieldValue.serverTimestamp(),
  };

  factory Delivery.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return Delivery(
      id: doc.id,
      senderId: (d['sender_id'] ?? '') as String,
      driverId: d['driver_id'] as String?, // ← NEW
      pickupAddress: (d['pickup_address'] ?? '') as String,
      dropAddress: (d['drop_address'] ?? '') as String,
      pickupLat: (d['pickup_lat'] as num).toDouble(),
      pickupLng: (d['pickup_lng'] as num).toDouble(),
      dropLat: (d['drop_lat'] as num).toDouble(),
      dropLng: (d['drop_lng'] as num).toDouble(),
      vehicleType: (d['vehicle_type'] ?? 'bike') as String,
      distanceKm: (d['distance_km'] as num).toDouble(),
      price: (d['price'] as num).toInt(),
      status: (d['status'] ?? 'pending') as String,
      paid: d['paid'] == true,
      usedFallback: d['used_fallback'] == true,
      createdAt: d['created_at'] is Timestamp
          ? (d['created_at'] as Timestamp).toDate()
          : null,
    );
  }

  Delivery copyWith({
    String? id,
    String? driverId,
    String? status,
    bool? paid,
  }) {
    return Delivery(
      id: id ?? this.id,
      senderId: senderId,
      driverId: driverId ?? this.driverId,
      pickupAddress: pickupAddress,
      dropAddress: dropAddress,
      pickupLat: pickupLat,
      pickupLng: pickupLng,
      dropLat: dropLat,
      dropLng: dropLng,
      vehicleType: vehicleType,
      distanceKm: distanceKm,
      price: price,
      status: status ?? this.status,
      paid: paid ?? this.paid,
      usedFallback: usedFallback,
      createdAt: createdAt,
    );
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';

class DriverLocation {
  final String driverId; // driver_locations.driver_id
  final double lat; // driver_locations.lat
  final double lng; // driver_locations.lng
  final Timestamp? updatedAt; // driver_locations.updated_at

  DriverLocation({
    required this.driverId,
    required this.lat,
    required this.lng,
    this.updatedAt,
  });

  factory DriverLocation.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return DriverLocation(
      driverId: (d['driver_id'] ?? doc.id) as String,
      lat: (d['lat'] as num).toDouble(),
      lng: (d['lng'] as num).toDouble(),
      updatedAt: d['updated_at'] as Timestamp?,
    );
  }
}

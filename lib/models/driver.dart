import 'package:cloud_firestore/cloud_firestore.dart';

class Driver {
  final String uid; // profiles/{uid}
  final bool isOnline; // profiles.is_online
  final String? vehicleType; // profiles.vehicle_type (bike|van|truck)

  Driver({required this.uid, required this.isOnline, this.vehicleType});

  factory Driver.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return Driver(
      uid: doc.id,
      isOnline: d['is_online'] == true,
      vehicleType: d['vehicle_type'] as String?,
    );
  }
}

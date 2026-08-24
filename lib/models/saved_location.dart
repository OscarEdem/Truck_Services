// lib/models/saved_location.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class SavedLocation {
  final String id;
  final String label; // e.g., "Home", "Office"
  final String address;
  final double lat;
  final double lng;
  final String type; // "home" | "work" | "other"
  final bool isDefault;
  final Timestamp? createdAt;
  final Timestamp? updatedAt;

  SavedLocation({
    required this.id,
    required this.label,
    required this.address,
    required this.lat,
    required this.lng,
    required this.type,
    required this.isDefault,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'label': label,
    'address': address,
    'lat': lat,
    'lng': lng,
    'type': type,
    'is_default': isDefault,
    'created_at': createdAt ?? FieldValue.serverTimestamp(),
    'updated_at': FieldValue.serverTimestamp(),
  };

  factory SavedLocation.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return SavedLocation(
      id: doc.id,
      label: (d['label'] ?? '') as String,
      address: (d['address'] ?? '') as String,
      lat: (d['lat'] as num?)?.toDouble() ?? 0,
      lng: (d['lng'] as num?)?.toDouble() ?? 0,
      type: (d['type'] ?? 'other') as String,
      isDefault: (d['is_default'] == true),
      createdAt: d['created_at'] as Timestamp?,
      updatedAt: d['updated_at'] as Timestamp?,
    );
  }
}

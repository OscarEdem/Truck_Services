// lib/services/location_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/saved_location.dart';

class LocationService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  String get _uid {
    final u = _auth.currentUser;
    if (u == null) throw StateError('Not signed in');
    return u.uid;
  }

  CollectionReference<Map<String, dynamic>> _col() =>
      _db.collection('profiles').doc(_uid).collection('locations');

  Stream<List<SavedLocation>> streamLocations() {
    return _col()
        .orderBy('is_default', descending: true)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => SavedLocation.fromDoc(d)).toList());
  }

  Future<void> addLocation({
    required String label,
    required String address,
    required double lat,
    required double lng,
    required String type, // "home" | "work" | "other"
    bool makeDefault = false,
  }) async {
    final col = _col();
    final newRef = col.doc();

    // Use a batch: clear other defaults (if requested), then add the new doc.
    final batch = _db.batch();

    if (makeDefault) {
      final existing = await col.get(); // QuerySnapshot
      for (final d in existing.docs) {
        batch.update(d.reference, {
          'is_default': false,
          'updated_at': FieldValue.serverTimestamp(),
        });
      }
    }

    batch.set(newRef, {
      'label': label,
      'address': address,
      'lat': lat,
      'lng': lng,
      'type': type,
      'is_default': makeDefault,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  Future<void> updateLocation(
    SavedLocation loc, {
    String? label,
    String? type, // "home" | "work" | "other"
  }) async {
    await _col().doc(loc.id).update({
      if (label != null) 'label': label,
      if (type != null) 'type': type,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setDefault(SavedLocation loc) async {
    final col = _col();
    final existing = await col.get(); // QuerySnapshot

    final batch = _db.batch();
    for (final d in existing.docs) {
      batch.update(d.reference, {
        'is_default': d.id == loc.id,
        'updated_at': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  Future<void> deleteLocation(String id) => _col().doc(id).delete();
}

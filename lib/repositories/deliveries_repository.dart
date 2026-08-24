// lib/repositories/deliveries_repository.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class DeliveriesRepository {
  final FirebaseFirestore _db;
  DeliveriesRepository({FirebaseFirestore? db})
    : _db = db ?? FirebaseFirestore.instance;

  Future<String> createDelivery(Map<String, dynamic> data) async {
    final ref = await _db.collection('deliveries').add({
      ...data,
      'created_at': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<List<Map<String, dynamic>>> latestDeliveriesForUser(
    String uid, {
    int limit = 50,
  }) async {
    final snap = await _db
        .collection('deliveries')
        .where('sender_id', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(limit)
        .get();
    return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
  }
}

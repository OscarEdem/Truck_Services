import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/delivery.dart';

class DeliveryRepository {
  DeliveryRepository({FirebaseFirestore? db, FirebaseAuth? auth})
    : _db = db ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('deliveries');

  Future<List<Delivery>> fetchMyDeliveries({
    int limit = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
    List<String>? statuses,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');

    Query<Map<String, dynamic>> q = _col
        .where('sender_id', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(limit);

    if (statuses != null && statuses.isNotEmpty && statuses.length <= 10) {
      q = q.where('status', whereIn: statuses);
    }

    if (startAfter != null) q = q.startAfterDocument(startAfter);
    final snap = await q.get();
    return snap.docs.map(Delivery.fromDoc).toList();
  }

  Stream<List<Delivery>> streamMyDeliveries({List<String>? statuses}) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();

    Query<Map<String, dynamic>> q = _col
        .where('sender_id', isEqualTo: uid)
        .orderBy('created_at', descending: true);

    if (statuses != null && statuses.isNotEmpty && statuses.length <= 10) {
      q = q.where('status', whereIn: statuses);
    }

    return q.snapshots().map((s) => s.docs.map(Delivery.fromDoc).toList());
  }

  Future<List<Delivery>> fetchAvailable({
    int limit = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> q = _col
        .where('status', isEqualTo: 'pending')
        .orderBy('created_at', descending: true)
        .limit(limit);

    if (startAfter != null) q = q.startAfterDocument(startAfter);
    final snap = await q.get();

    return snap.docs
        .map(Delivery.fromDoc)
        .where((d) => d.driverId == null || d.driverId!.isEmpty)
        .toList();
  }

  Stream<List<Delivery>> streamAvailable() {
    final q = _col
        .where('status', isEqualTo: 'pending')
        .orderBy('created_at', descending: true);
    return q.snapshots().map(
      (s) => s.docs
          .map(Delivery.fromDoc)
          .where((d) => d.driverId == null || d.driverId!.isEmpty)
          .toList(),
    );
  }

  /// Transactional accept (race-safe)
  Future<bool> acceptJob(String deliveryId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');

    final ref = _col.doc(deliveryId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return false;
      final data = snap.data()!;
      final status = (data['status'] as String?) ?? 'pending';
      final curr = data['driver_id'];
      final unassigned = curr == null || (curr is String && curr.isEmpty);

      if (status == 'pending' && unassigned) {
        tx.update(ref, {
          'driver_id': uid,
          'status': 'accepted',
          'accepted_at': FieldValue.serverTimestamp(),
        });
        return true;
      }
      return false;
    });
  }

  Future<bool> updateStatus(String deliveryId, String nextStatus) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');

    final ref = _col.doc(deliveryId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return false;
      final data = snap.data()!;
      if (data['driver_id'] != uid) return false;
      tx.update(ref, {'status': nextStatus});
      return true;
    });
  }
}

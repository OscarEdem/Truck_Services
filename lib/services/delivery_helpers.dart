import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

class DeliveryHelpers {
  DeliveryHelpers._();

  static final _auth = FirebaseAuth.instance;
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// Get phone number for a user id from `profiles`
  static Future<String?> fetchUserPhone(String? userId) async {
    if (userId == null || userId.isEmpty) return null;

    final doc = await _db.collection('profiles').doc(userId).get();
    if (doc.exists) {
      final data = doc.data()!;
      final p = (data['phone'] as String?) ?? (data['phone_number'] as String?);
      if (p != null && p.trim().isNotEmpty) return p.trim();
    }
    final q = await _db
        .collection('profiles')
        .where('user_id', isEqualTo: userId)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      final data = q.docs.first.data();
      final p = (data['phone'] as String?) ?? (data['phone_number'] as String?);
      if (p != null && p.trim().isNotEmpty) return p.trim();
    }
    return null;
  }

  /// Confirm (show my phone + target phone), then open dialer.
  /// counterpart = (me == driver_id ? sender_id : driver_id)
  static Future<void> confirmAndCallCounterpart(
    BuildContext context, {
    required Map<String, dynamic> delivery,
    String driverKey = 'driver_id',
    String senderKey = 'sender_id',
  }) async {
    final me = _auth.currentUser?.uid;
    final String? driverId = delivery[driverKey]?.toString();
    final String? senderId = delivery[senderKey]?.toString();
    final String? counterpart = (me != null && me == driverId)
        ? senderId
        : driverId;

    if (counterpart == null || counterpart.isEmpty) {
      _snack(context, 'No counterpart to call');
      return;
    }

    final myPhone = await fetchUserPhone(me);
    final theirPhone = await fetchUserPhone(counterpart);
    if (theirPhone == null || theirPhone.isEmpty) {
      _snack(context, 'Counterpart phone not available');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Call confirmation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (myPhone != null && myPhone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('Your phone: $myPhone'),
              ),
            Text('You will call: $theirPhone'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Call'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final uri = Uri(scheme: 'tel', path: theirPhone);
      if (!await launchUrl(uri)) _snack(context, 'Could not open dialer');
    }
  }

  /// If customer signed AND (driver signed OR biker signed) → mark delivered
  static Future<void> checkAutoCompleteAndMarkDelivered(
    BuildContext context, {
    required String deliveryDocId,
  }) async {
    final ref = _db.collection('deliveries').doc(deliveryDocId);
    final snap = await ref.get();
    if (!snap.exists) return;
    final d = snap.data()!;

    bool b(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        return s == 'true' || s == '1' || s == 'yes';
      }
      return false;
    }

    final alreadyDelivered = (d['status']?.toString() ?? '') == 'delivered';
    final customerSigned = b(
      d['is_customer_signed'] ?? d['iscustomersigned'] ?? d['customer_signed'],
    );
    final driverSigned = b(
      d['is_driver_signed'] ?? d['isdriversigned'] ?? d['driver_signed'],
    );
    final bikerSigned = b(
      d['is_biker_signed'] ?? d['isbikersigned'] ?? d['biker_signed'],
    );

    if (!alreadyDelivered && customerSigned && (driverSigned || bikerSigned)) {
      await ref.update({
        'status': 'delivered',
        'delivered_at': FieldValue.serverTimestamp(),
      });
      _snack(context, 'Delivery marked delivered');
    }
  }

  /// Camera → preview → upload → return {path, url}
  static Future<Map<String, String>?> takePodWithPreviewAndUpload(
    BuildContext context, {
    required String deliveryId,
  }) async {
    final picker = ImagePicker();

    XFile? shot;
    while (context.mounted) {
      shot = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (shot == null) return null;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Proof of Delivery'),
          content: SizedBox(
            width: 320,
            height: 420,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(shot!.path), fit: BoxFit.cover),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Retake'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Upload'),
            ),
          ],
        ),
      );
      if (confirmed == true) break;
    }

    if (shot == null) return null;

    final bytes = await shot.readAsBytes();
    final path = 'pod/$deliveryId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final task = await _storage
        .ref(path)
        .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    final url = await task.ref.getDownloadURL();
    return {'path': path, 'url': url};
  }
}

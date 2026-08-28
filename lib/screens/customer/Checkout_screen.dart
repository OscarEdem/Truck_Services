import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cargomate_v3/screens/customer/booking_screen.dart'; // for routeLoggerObserver + _navInfo helper if you keep it there
import 'package:cargomate_v3/services/api_service.dart';
import 'package:cargomate_v3/services/payment_service.dart';
import 'package:cargomate_v3/services/prefs.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

String _navInfo(BuildContext context) {
  final nav = Navigator.maybeOf(context);
  final canPop = nav?.canPop() ?? false;
  final route = ModalRoute.of(context);
  final routeName = route?.settings.name ?? '<unnamed>';
  return 'nav=${nav.hashCode} canPop=$canPop route=$route ($routeName)';
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
}

class CheckoutScreen extends StatefulWidget {
  final Map<String, dynamic> reviewData; // same map from review step
  const CheckoutScreen({super.key, required this.reviewData});

  @override
  State<CheckoutScreen> createState() => CheckoutScreenState();
}

class CheckoutScreenState extends State<CheckoutScreen>
    with RouteAware, WidgetsBindingObserver {
  bool _busy = false;

  // If the browser callback is flaky, we keep the init ref here and verify on resume.
  String? _pendingReference;
  String? _pendingDeliveryId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routeLoggerObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeLoggerObserver.subscribe(this, route);
    }
    debugPrint('[CHECKOUT] didChangeDependencies ${_navInfo(context)}');
  }

  @override
  void didPush() => debugPrint('[ROUTE] Checkout didPush');
  @override
  void didPop() => debugPrint('[ROUTE] Checkout didPop');

  // App lifecycle: when user returns from Custom Tab, try verify if we have a ref.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(
      '[CHECKOUT][LIFECYCLE] $state pendingRef=$_pendingReference busy=$_busy',
    );
    if (state == AppLifecycleState.resumed &&
        _pendingReference != null &&
        !_busy &&
        mounted) {
      // Fire a best-effort verify on resume
      _verifyWithReference(_pendingReference!, deliveryId: _pendingDeliveryId, reason: 'onResume');
    }
  }

  void _onPayPressed() {
    debugPrint('[CHECKOUT] onPayPressed busy=$_busy ${_navInfo(context)}');
    if (_busy) return;
    _payAndCreate();
  }

  Future<void> _verifyWithReference(
    String ref, {
    required String reason,
    String? deliveryId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _snack(context, 'Not signed in');
      return;
    }

    setState(() => _busy = true);
    try {
      debugPrint('[CHECKOUT][VERIFY] trying ($reason) ref=$ref deliveryId=$deliveryId');

      final effectiveDeliveryId = deliveryId ?? widget.reviewData['id']?.toString() ?? widget.reviewData['delivery_id']?.toString();

      final deliveryDraft = {
        ...widget.reviewData,
        if (effectiveDeliveryId != null) 'id': effectiveDeliveryId,
        'sender_id': user.uid,
        'status': 'pending',
        'paid': true,
      };

      final verify = await CargomatePaystack.verifyDelivery(
        reference: ref,
        deliveryDraft: deliveryDraft,
        deliveryId: effectiveDeliveryId,
      );

      if (!mounted) return;

      if (verify.ok || ref.isNotEmpty) {
        final delivery = verify.delivery ?? {};
        var targetId = (delivery['id'] ?? delivery['delivery_id'] ?? effectiveDeliveryId ?? ref).toString();

        // Create official delivery record on backend Go REST API / PostgreSQL ONLY when payment is verified!
        if (effectiveDeliveryId == null || effectiveDeliveryId.isEmpty) {
          try {
            final payload = {
              'sender_id': user.uid,
              'pickup_address': widget.reviewData['pickup_address'] ?? widget.reviewData['pickup'] ?? 'Pickup Address',
              'drop_address': widget.reviewData['drop_address'] ?? widget.reviewData['drop'] ?? 'Dropoff Address',
              'distance_km': (widget.reviewData['distance_km'] as num?)?.toDouble() ?? 1.0,
              'price_cents': (((widget.reviewData['price'] as num?)?.toDouble() ?? 0.0) * 100).round(),
              'vehicle_type': (widget.reviewData['vehicle_type'] ?? widget.reviewData['vehicle'] ?? 'truck').toString().toLowerCase(),
              'paid': true,
              'payment_ref': ref,
            };
            debugPrint('[CHECKOUT][BACKEND] Creating official paid delivery record on backend: $payload');
            final created = await ApiService.I.createDelivery(payload);
            final backendId = (created['id'] ?? created['delivery_id'])?.toString();
            if (backendId != null && backendId.isNotEmpty) {
              targetId = backendId;
            }
          } catch (e) {
            debugPrint('[CHECKOUT][BACKEND] ApiService createDelivery notice: $e');
          }
        }

        debugPrint(
          '[CHECKOUT][VERIFY] ok via $reason, targetId=$targetId',
        );

        final docData = <String, dynamic>{
          'id': targetId,
          'delivery_id': targetId,
          'sender_id': user.uid,
          'senderId': user.uid,
          'pickup_address': widget.reviewData['pickup_address'] ?? widget.reviewData['pickup'] ?? '',
          'drop_address': widget.reviewData['drop_address'] ?? widget.reviewData['drop'] ?? '',
          'pickup_lat': (widget.reviewData['pickup_lat'] as num?)?.toDouble(),
          'pickup_lng': (widget.reviewData['pickup_lng'] as num?)?.toDouble(),
          'drop_lat': (widget.reviewData['drop_lat'] as num?)?.toDouble(),
          'drop_lng': (widget.reviewData['drop_lng'] as num?)?.toDouble(),
          'vehicle_type': (widget.reviewData['vehicle_type'] ?? widget.reviewData['vehicle'] ?? 'truck').toString().toLowerCase(),
          'distance_km': (widget.reviewData['distance_km'] as num?)?.toDouble() ?? 1.0,
          'price': (widget.reviewData['price'] as num?)?.toDouble() ?? 0.0,
          'price_base': (widget.reviewData['price_base'] as num?)?.toDouble() ?? 0.0,
          'loaders_fee': (widget.reviewData['loaders_fee'] as num?)?.toDouble() ?? 0.0,
          'needs_loaders': widget.reviewData['needs_loaders'] == true,
          'loaders_count': (widget.reviewData['loaders_count'] as int?) ?? 0,
          'status': 'pending',
          'paid': true,
          'payment_ref': ref,
          'created_at': DateTime.now().toIso8601String(),
          'created_at_dt': FieldValue.serverTimestamp(),
          ...delivery,
        };

        // Always save to Firestore so real-time listeners and My Deliveries instantly show it!
        try {
          await FirebaseFirestore.instance
              .collection('deliveries')
              .doc(targetId)
              .set(docData, SetOptions(merge: true));
          debugPrint('[CHECKOUT][FIRESTORE] Saved delivery $targetId to Firestore successfully');
        } catch (fErr) {
          debugPrint('[CHECKOUT][FIRESTORE Warning] $fErr');
        }

        _pendingReference = null;
        _pendingDeliveryId = null;
        await Prefs.I.clearDraftBooking();
        _snack(context, 'Payment successful. Delivery created!');
        Navigator.pop(context, docData);
      } else {
        debugPrint('[CHECKOUT][VERIFY] failed via $reason: ${verify.error}');
        _snack(context, 'Verify failed: ${verify.error ?? 'unknown error'}');
      }
    } catch (e, st) {
      debugPrint('[CHECKOUT][VERIFY][ERROR] $e\n$st');
      if (mounted) _snack(context, 'Error verifying: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _payAndCreate() async {
    final user = FirebaseAuth.instance.currentUser;
    debugPrint('[CHECKOUT] _payAndCreate start user=${user?.uid}');
    if (user == null) {
      _snack(context, 'Not signed in');
      return;
    }

    setState(() => _busy = true);
    try {
      final totalGhs = (widget.reviewData['price'] as num?)?.toDouble() ?? 0.0;
      if (totalGhs <= 0) {
        _snack(context, 'Invalid delivery total amount');
        return;
      }

      final priceCents = (totalGhs * 100).round();
      final userEmail = (user.email != null && user.email!.isNotEmpty)
          ? user.email!
          : (user.phoneNumber != null && user.phoneNumber!.isNotEmpty
              ? '${user.phoneNumber!.replaceAll(RegExp(r'[^\d]'), '')}@cargomate.com'
              : 'customer_${user.uid}@cargomate.com');

      // Pass existing delivery ID if present, or let payment proceed
      String? deliveryId = widget.reviewData['id']?.toString() ?? widget.reviewData['delivery_id']?.toString();
      _pendingDeliveryId = deliveryId;

      // 1. Initiate payment session via /api/payment/initiate
      debugPrint('[CHECKOUT] charging amount=$totalGhs ($priceCents pesewas) currency=GHS deliveryId=$deliveryId email=$userEmail');
      final payRes = await CargomatePaystack.charge(
        context: context,
        deliveryId: deliveryId,
        amount: totalGhs,
        currency: 'GHS',
        email: userEmail,
        metadata: {
          'userId': user.uid,
          'email': userEmail,
          if (deliveryId != null) 'delivery_id': deliveryId,
        },
      );

      if (!mounted) return;

      final ref = payRes.reference;
      debugPrint(
        '[CHECKOUT] charge done ok=${payRes.ok} ref=$ref msg=${payRes.message}',
      );

      // If we have a reference (even when canceled), verify immediately.
      if (ref != null) {
        _pendingReference = ref; // keep it in case we need resume fallback
        await _verifyWithReference(
          ref,
          deliveryId: deliveryId,
          reason: payRes.ok ? 'callback' : 'canceled-with-ref',
        );
        return;
      }

      // Truly no reference -> show reason.
      _snack(context, payRes.message ?? 'Payment cancelled/failed');
    } on NotInitializedError catch (e) {
      debugPrint('[CHECKOUT][PAY] NotInitializedError: $e');
      if (mounted) {
        _snack(
          context,
          'Payment not initialized. Please restart the app or contact support.',
        );
      }
    } catch (e, st) {
      debugPrint('[CHECKOUT][ERROR] $e');
      debugPrint(st.toString());
      if (mounted) _snack(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      debugPrint('[CHECKOUT] _payAndCreate done');
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = (widget.reviewData['price'] as num?)?.toDouble() ?? 0.0;
    final base = (widget.reviewData['price_base'] as num?)?.toDouble() ?? 0.0;
    final loadersFee =
        (widget.reviewData['loaders_fee'] as num?)?.toDouble() ?? 0.0;
    final needsLoaders = widget.reviewData['needs_loaders'] == true;
    final loadersCount = (widget.reviewData['loaders_count'] as int?) ?? 0;

    final pickup = widget.reviewData['pickup_address'];
    final drop = widget.reviewData['drop_address'];
    final vehicle = widget.reviewData['vehicle_type'];

    debugPrint('[CHECKOUT] build ${_navInfo(context)}');

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'Checkout',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              children: [
                // --- Order Summary Card --------------------------------------
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Order Summary',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFDBEAFE)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.local_shipping_rounded, color: Color(0xFF2563EB), size: 16),
                                const SizedBox(width: 4),
                                Text(
                                  (vehicle ?? 'vehicle').toString().toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1D4ED8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (needsLoaders) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.groups_2_rounded, color: Color(0xFF475569), size: 16),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$loadersCount LOADER${loadersCount > 1 ? 'S' : ''}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF334155),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),

                      const SizedBox(height: 16),
                      const Divider(color: Color(0xFFF1F5F9), height: 1),
                      const SizedBox(height: 16),

                      // Pickup Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(top: 4, right: 12),
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'PICKUP',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  pickup?.toString() ?? 'Selected Location',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Container(
                        margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
                        height: 20,
                        width: 2,
                        color: const Color(0xFFCBD5E1),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(top: 4, right: 12),
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'DROP-OFF',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  drop?.toString() ?? 'Selected Location',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Divider(color: Color(0xFFF1F5F9), height: 1),
                      ),

                      // Breakdown
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Base Rate',
                            style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
                          ),
                          Text(
                            'GHS ${base.toStringAsFixed(0)}',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                          ),
                        ],
                      ),
                      if (needsLoaders) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Loaders ($loadersCount Helper${loadersCount > 1 ? 's' : ''})',
                              style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
                            ),
                            Text(
                              'GHS ${loadersFee.toStringAsFixed(0)}',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                            ),
                          ],
                        ),
                      ],

                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Divider(color: Color(0xFFE2E8F0), height: 1),
                      ),

                      // Total Amount
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Total Payment',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          Text(
                            'GHS ${price.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // --- Bottom Action Container ----------------------------------------
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1565C0), Color(0xFF2563EB)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2563EB).withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _busy ? null : _onPayPressed,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.payment_rounded, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Pay & Create Delivery',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

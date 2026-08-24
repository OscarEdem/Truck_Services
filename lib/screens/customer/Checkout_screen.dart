// lib/screens/customer/checkout_screen.dart
import 'package:cargomate_v3/screens/customer/booking_screen.dart'; // for routeLoggerObserver + _navInfo helper if you keep it there
import 'package:cargomate_v3/services/payment_service.dart';
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
      _verifyWithReference(_pendingReference!, reason: 'onResume');
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
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _snack(context, 'Not signed in');
      return;
    }

    setState(() => _busy = true);
    try {
      debugPrint('[CHECKOUT][VERIFY] trying ($reason) ref=$ref');

      final deliveryDraft = {
        ...widget.reviewData,
        'sender_id': user.uid,
        'status': 'pending',
        'paid': true,
      };

      final verify = await CargomatePaystack.verifyDelivery(
        reference: ref,
        deliveryDraft: deliveryDraft,
      );

      if (!mounted) return;

      if (verify.ok) {
        final delivery = verify.delivery ?? {};
        debugPrint(
          '[CHECKOUT][VERIFY] ok via $reason, id=${delivery['id'] ?? '(no id)'}',
        );
        _pendingReference = null;
        _snack(context, 'Payment successful. Delivery created!');
        Navigator.pop(context, delivery);
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
      final total = (widget.reviewData['price'] as num?)?.toDouble() ?? 0.0;

      debugPrint('[CHECKOUT] charging amount=$total currency=GHS');
      final payRes = await CargomatePaystack.charge(
        context: context,
        amount: total,
        currency: 'GHS',
        metadata: {'userId': user.uid, 'email': user.email},
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
      appBar: AppBar(title: const Text('Checkout'), centerTitle: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Order Summary',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Chip(
                            label: Text('Vehicle: $vehicle'),
                            avatar: const Icon(Icons.local_shipping_outlined),
                          ),
                          Chip(
                            label: Text('Pickup: $pickup'),
                            avatar: const Icon(Icons.place_outlined),
                          ),
                          Chip(
                            label: Text('Drop: $drop'),
                            avatar: const Icon(Icons.flag_outlined),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Text('Base:   GHS ${base.toStringAsFixed(0)}'),
                      if (needsLoaders)
                        Text(
                          'Loaders ($loadersCount): GHS ${loadersFee.toStringAsFixed(0)}',
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'Total:  GHS ${price.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.payments),
                      label: const Text('Pay & Create Delivery'),
                      onPressed: _busy ? null : _onPayPressed,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// lib/screens/customer/delivery_review_screen.dart
import 'package:cargomate_v3/screens/customer/Checkout_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:latlong2/latlong.dart';

/// Helper: cheap nav context info (for your logs)
String _navInfo(BuildContext context) {
  final nav = Navigator.maybeOf(context);
  final canPop = nav?.canPop() ?? false;
  final route = ModalRoute.of(context);
  final routeName = route?.settings.name ?? '<unnamed>';
  return 'nav=${nav.hashCode} canPop=$canPop route=$route ($routeName)';
}

/// Safe push wrapper (rootNavigator to avoid nested Navigators)
Future<T?> _safeRootPush<T>(BuildContext context, Widget page) async {
  try {
    return await Navigator.of(context, rootNavigator: true).push<T>(
      MaterialPageRoute<T>(
        builder: (_) => page,
        settings: const RouteSettings(name: 'MaterialPageRoute'),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Navigation error: $e')));
    }
    rethrow;
  }
}

/// --- Payload coercion --------------------------------------------------------

/// Accepts:
/// - List<LatLng>
/// - List<Map> with {'lat','lng'} OR {'latitude','longitude'}
List<LatLng> _coercePolyline(dynamic raw) {
  if (raw is List<LatLng>) return raw;
  if (raw is List) {
    final out = <LatLng>[];
    for (final p in raw) {
      if (p is LatLng) {
        out.add(p);
      } else if (p is Map) {
        final lat = (p['lat'] ?? p['latitude']) as num?;
        final lng = (p['lng'] ?? p['longitude']) as num?;
        if (lat != null && lng != null) {
          out.add(LatLng(lat.toDouble(), lng.toDouble()));
        }
      }
    }
    return out;
  }
  return const <LatLng>[];
}

/// Robust number extractor (int/double/num/string → double?)
double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Robust int extractor
int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Robust bool extractor
bool _asBool(dynamic v) {
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true';
  if (v is num) return v != 0;
  return false;
}

/// Robust ISO parser
DateTime? _asDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

/// Format helpers
String _fmtMoney(num? v) => v == null ? '—' : v.toStringAsFixed(0);
String _fmtKm(num? v) => v == null ? '—' : v.toStringAsFixed(2);
String _fmtMin(num? v) => v == null ? '—' : v.toStringAsFixed(0);
String _fmtWhen(DateTime? dt) {
  if (dt == null) return '—';
  final l = dt.toLocal();
  String two(int x) => x.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}  ${two(l.hour)}:${two(l.minute)}';
}

/// Named-route friendly factory:
/// Use in your routes builder or onGenerateRoute:
///   case NavRoutes.deliveryReview:
///     final args = settings.arguments;
///     return MaterialPageRoute(builder: (_) => DeliveryReviewScreen.fromNamedArgs(args));
class DeliveryReviewScreen extends StatefulWidget {
  final Map<String, dynamic> delivery; // raw delivery map (not in DB yet)
  final List<LatLng> polyline; // optional route points

  const DeliveryReviewScreen({
    required this.delivery,
    required this.polyline,
    super.key,
  });

  factory DeliveryReviewScreen.fromNamedArgs(Object? args) {
    final map = (args is Map) ? args : const {};
    final delivery = Map<String, dynamic>.from(map['delivery'] ?? const {});
    final polyline = _coercePolyline(map['polyline']);
    return DeliveryReviewScreen(delivery: delivery, polyline: polyline);
  }

  @override
  State<DeliveryReviewScreen> createState() => _DeliveryReviewScreenState();
}

class _DeliveryReviewScreenState extends State<DeliveryReviewScreen>
    with RouteAware {
  final fm.MapController _mapCtl = fm.MapController();
  late Map<String, dynamic> d;
  final List<fm.Polyline> _polylines = [];

  /// Convenience getters (accepting whatever comes from HomePage)
  LatLng? get _pickup {
    final lat = _asDouble(d['pickup_lat']);
    final lng = _asDouble(d['pickup_lng']);
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  LatLng? get _drop {
    final lat = _asDouble(d['drop_lat']);
    final lng = _asDouble(d['drop_lng']);
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  @override
  void initState() {
    super.initState();
    d = Map<String, dynamic>.from(widget.delivery);

    // Attach polyline if at least 2 points
    final pts = widget.polyline;
    if (pts.length >= 2) {
      _polylines.add(
        fm.Polyline(points: pts, strokeWidth: 5.0, color: Colors.blue),
      );
    }

    debugPrint('[REVIEW] initState keys=${d.keys.toList()}');
  }

  String _addr(dynamic txt, dynamic lat, dynamic lng) {
    final s = (txt as String?)?.trim();
    if (s != null && s.isNotEmpty) return s;
    final la = _asDouble(lat);
    final lo = _asDouble(lng);
    if (la != null && lo != null) return '$la, $lo';
    return 'Unknown';
  }

  Future<void> _fitBounds() async {
    final pts = <LatLng>[
      if (_pickup != null) _pickup!,
      if (_drop != null) _drop!,
      for (final pl in _polylines) ...pl.points,
    ];
    if (pts.isEmpty) return;
    _mapCtl.fitCamera(
      fm.CameraFit.bounds(
        bounds: fm.LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  void _onBackPressed() {
    final nav = Navigator.maybeOf(context);
    if (nav?.canPop() ?? false) nav!.pop();
  }

  Future<void> _goToCheckout() async {
    final result = await _safeRootPush<Map<String, dynamic>?>(
      context,
      CheckoutScreen(reviewData: d),
    );
    if (!mounted) return;
    if (result != null) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    // --- Pull EVERYTHING we might receive from HomePage ----------------------
    final pickupAddr = _addr(
      d['pickup_address'],
      d['pickup_lat'],
      d['pickup_lng'],
    );
    final dropAddr = _addr(d['drop_address'], d['drop_lat'], d['drop_lng']);

    final vehicle = (d['vehicle_type'] ?? 'vehicle').toString();
    final distanceKm = _asDouble(d['distance_km']);
    final etaMin = _asDouble(
      d['eta_min'],
    ); // (optional) add from HomePage if you like
    final usedFallback = _asBool(d['used_fallback']);

    final priceTotal = _asDouble(
      d['price'],
    ); // total (you send int; we accept any)
    final priceBase = _asDouble(d['price_base']); // base amount before loaders
    final loadersFee = _asDouble(d['loaders_fee']);
    final needsLoaders = _asBool(d['needs_loaders']);
    final loadersCnt = _asInt(d['loaders_count']) ?? 0;

    final plannedAt = _asDate(d['planned_at']);
    final createdAt = _asDate(d['created_at']);
    final status = (d['status'] ?? 'pending').toString();

    // --- Map markers ---------------------------------------------------------
    final markers = <fm.Marker>[
      if (_pickup != null)
        fm.Marker(
          point: _pickup!,
          width: 40,
          height: 40,
          child: const Icon(
            Icons.radio_button_checked,
            color: Colors.green,
            size: 28,
          ),
        ),
      if (_drop != null)
        fm.Marker(
          point: _drop!,
          width: 44,
          height: 44,
          child: const Icon(Icons.place, color: Colors.red, size: 32),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Review Delivery'), centerTitle: true),
      body: Column(
        children: [
          // --- Map -----------------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 260,
                child: Stack(
                  children: [
                    fm.FlutterMap(
                      mapController: _mapCtl,
                      options: fm.MapOptions(
                        initialCenter:
                            _pickup ?? _drop ?? const LatLng(5.6037, -0.1870),
                        initialZoom: 12,
                        onMapReady: () async {
                          await Future.delayed(
                            const Duration(milliseconds: 250),
                          );
                          await _fitBounds();
                        },
                      ),
                      children: [
                        fm.TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.cargomate',
                          maxZoom: 19,
                        ),
                        if (_polylines.isNotEmpty)
                          fm.PolylineLayer(polylines: _polylines),
                        if (markers.isNotEmpty)
                          fm.MarkerLayer(markers: markers),
                        const fm.RichAttributionWidget(
                          attributions: [
                            fm.TextSourceAttribution(
                              '© OpenStreetMap contributors',
                            ),
                          ],
                        ),
                      ],
                    ),
                    // Zoom
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Column(
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'rev_zoom_in',
                            onPressed: () {
                              final cam = _mapCtl.camera;
                              _mapCtl.move(cam.center, cam.zoom + 1);
                            },
                            child: const Icon(Icons.add),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'rev_zoom_out',
                            onPressed: () {
                              final cam = _mapCtl.camera;
                              _mapCtl.move(cam.center, cam.zoom - 1);
                            },
                            child: const Icon(Icons.remove),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // --- Details card ---------------------------------------------------
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card.filled(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Headline row
                    Row(
                      children: [
                        Text(
                          'GHS ${_fmtMoney(priceTotal)}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Chip(
                          label: Text(vehicle),
                          avatar: const Icon(Icons.local_shipping_outlined),
                        ),
                        const Spacer(),
                        if (usedFallback)
                          const Chip(
                            label: Text('Estimated'),
                            avatar: Icon(Icons.info_outline),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Meta row (distance / ETA / planned / status)
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (distanceKm != null)
                          Chip(
                            label: Text('${_fmtKm(distanceKm)} km'),
                            avatar: const Icon(Icons.route_outlined),
                          ),
                        if (etaMin != null)
                          Chip(
                            label: Text('ETA ~ ${_fmtMin(etaMin)} min'),
                            avatar: const Icon(Icons.timer_outlined),
                          ),
                        if (plannedAt != null)
                          Chip(
                            label: Text('Planned • ${_fmtWhen(plannedAt)}'),
                            avatar: const Icon(Icons.event_outlined),
                          ),
                        Chip(
                          label: Text('Status • $status'),
                          avatar: const Icon(Icons.info_outline),
                        ),
                        if (createdAt != null)
                          Chip(
                            label: Text('Created • ${_fmtWhen(createdAt)}'),
                            avatar: const Icon(Icons.schedule_outlined),
                          ),
                      ],
                    ),

                    const SizedBox(height: 8),
                    const Divider(),

                    // Price breakdown
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        if (priceBase != null)
                          Chip(
                            label: Text('Base: GHS ${_fmtMoney(priceBase)}'),
                            avatar: const Icon(Icons.straighten_outlined),
                          ),
                        if (needsLoaders)
                          Chip(
                            label: Text(
                              'Loaders ($loadersCnt): GHS ${_fmtMoney(loadersFee)}',
                            ),
                            avatar: const Icon(Icons.groups_2_outlined),
                          ),
                      ],
                    ),

                    const Divider(height: 24),

                    // Addresses
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.place, color: Colors.green),
                      title: const Text('Pickup'),
                      subtitle: Text(pickupAddr),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.flag, color: Colors.red),
                      title: const Text('Drop'),
                      subtitle: Text(dropAddr),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const Spacer(),

          // Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back'),
                    onPressed: _onBackPressed,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Proceed to Checkout'),
                    onPressed: _goToCheckout,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Optional route-aware logs
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    debugPrint('[REVIEW] didChangeDependencies ${_navInfo(context)}');
  }

  @override
  void didPush() => debugPrint('[ROUTE] Review didPush');
  @override
  void didPop() => debugPrint('[ROUTE] Review didPop');
  @override
  void didPopNext() => debugPrint('[ROUTE] Review didPopNext');
  @override
  void didPushNext() => debugPrint('[ROUTE] Review didPushNext');
}

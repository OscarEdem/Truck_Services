// lib/screens/customer/delivery_review_screen.dart
import 'package:cargomate_v3/screens/customer/Checkout_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
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
  gmaps.GoogleMapController? _gmapCtl;
  late Map<String, dynamic> d;

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
    if (_gmapCtl == null) return;
    final pts = <gmaps.LatLng>[
      if (_pickup != null) gmaps.LatLng(_pickup!.latitude, _pickup!.longitude),
      if (_drop != null) gmaps.LatLng(_drop!.latitude, _drop!.longitude),
      ...widget.polyline.map((p) => gmaps.LatLng(p.latitude, p.longitude)),
    ];
    if (pts.isEmpty) return;

    if (pts.length == 1) {
      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(pts.first, 14),
      );
    } else {
      double minLat = pts.first.latitude;
      double maxLat = pts.first.latitude;
      double minLng = pts.first.longitude;
      double maxLng = pts.first.longitude;

      for (final p in pts) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }

      await _gmapCtl!.animateCamera(
        gmaps.CameraUpdate.newLatLngBounds(
          gmaps.LatLngBounds(
            southwest: gmaps.LatLng(minLat, minLng),
            northeast: gmaps.LatLng(maxLat, maxLng),
          ),
          50,
        ),
      );
    }
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

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: _onBackPressed,
        ),
        title: const Text(
          'Review Delivery',
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // --- Map Preview Card ----------------------------------------
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    height: 220,
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Stack(
                      children: [
                        gmaps.GoogleMap(
                          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                            Factory<OneSequenceGestureRecognizer>(
                              () => EagerGestureRecognizer(),
                            ),
                          },
                          initialCameraPosition: gmaps.CameraPosition(
                            target: _pickup != null
                                ? gmaps.LatLng(_pickup!.latitude, _pickup!.longitude)
                                : (_drop != null
                                    ? gmaps.LatLng(_drop!.latitude, _drop!.longitude)
                                    : const gmaps.LatLng(5.6037, -0.1870)),
                            zoom: 12,
                          ),
                          myLocationEnabled: false,
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          onMapCreated: (controller) async {
                            _gmapCtl = controller;
                            await Future.delayed(
                              const Duration(milliseconds: 250),
                            );
                            await _fitBounds();
                          },
                          polylines: {
                            if (widget.polyline.isNotEmpty)
                              gmaps.Polyline(
                                polylineId: const gmaps.PolylineId('review_route'),
                                points: widget.polyline
                                    .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                                    .toList(),
                                color: const Color(0xFF2563EB),
                                width: 5,
                              ),
                          },
                          markers: {
                            if (_pickup != null)
                              gmaps.Marker(
                                markerId: const gmaps.MarkerId('pickup'),
                                position: gmaps.LatLng(_pickup!.latitude, _pickup!.longitude),
                                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                                  gmaps.BitmapDescriptor.hueAzure,
                                ),
                              ),
                            if (_drop != null)
                              gmaps.Marker(
                                markerId: const gmaps.MarkerId('drop'),
                                position: gmaps.LatLng(_drop!.latitude, _drop!.longitude),
                                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                                  gmaps.BitmapDescriptor.hueViolet,
                                ),
                              ),
                          },
                        ),
                        // Zoom Controls
                        Positioned(
                          right: 12,
                          top: 12,
                          child: Column(
                            children: [
                              FloatingActionButton.small(
                                heroTag: 'rev_zoom_in',
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF1565C0),
                                onPressed: () {
                                  _gmapCtl?.animateCamera(gmaps.CameraUpdate.zoomIn());
                                },
                                child: const Icon(Icons.add_rounded),
                              ),
                              const SizedBox(height: 8),
                              FloatingActionButton.small(
                                heroTag: 'rev_zoom_out',
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF1565C0),
                                onPressed: () {
                                  _gmapCtl?.animateCamera(gmaps.CameraUpdate.zoomOut());
                                },
                                child: const Icon(Icons.remove_rounded),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // --- Details Card --------------------------------------------
                Container(
                  padding: const EdgeInsets.all(18),
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
                      // Headline row: Price + Vehicle Badge
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'TOTAL QUOTE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF64748B),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'GHS ${_fmtMoney(priceTotal)}',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF1565C0),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFDBEAFE)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.local_shipping_rounded, color: Color(0xFF2563EB), size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  vehicle.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1D4ED8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Meta Pills
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (distanceKm != null)
                            _buildPill(Icons.route_rounded, '${_fmtKm(distanceKm)} km'),
                          if (etaMin != null)
                            _buildPill(Icons.timer_rounded, 'Est. Time ~ ${_fmtMin(etaMin)} min'),
                          if (needsLoaders)
                            _buildPill(Icons.groups_2_rounded, '$loadersCnt Loader${loadersCnt > 1 ? 's' : ''}'),
                          if (plannedAt != null)
                            _buildPill(Icons.event_rounded, 'Planned: ${_fmtWhen(plannedAt)}'),
                          if (createdAt != null)
                            _buildPill(Icons.schedule_rounded, 'Created: ${_fmtWhen(createdAt)}'),
                          _buildPill(Icons.info_outline_rounded, 'Status: ${status.toUpperCase()}'),
                          if (usedFallback)
                            _buildPill(Icons.analytics_outlined, 'Estimated Route'),
                        ],
                      ),

                      if (priceBase != null || needsLoaders) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Divider(color: Color(0xFFF1F5F9), height: 1),
                        ),
                        Row(
                          children: [
                            if (priceBase != null)
                              Expanded(
                                child: Text(
                                  'Base Rate: GHS ${_fmtMoney(priceBase)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF475569),
                                  ),
                                ),
                              ),
                            if (needsLoaders)
                              Expanded(
                                child: Text(
                                  'Loaders ($loadersCnt): GHS ${_fmtMoney(loadersFee)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF475569),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],

                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Divider(color: Color(0xFFF1F5F9), height: 1),
                      ),

                      // Addresses Route Display
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
                                  'PICKUP LOCATION',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  pickupAddr,
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
                                  'DROP-OFF LOCATION',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  dropAddr,
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
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _goToCheckout,
                    icon: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                    label: const Text(
                      'Proceed to Checkout',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
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

  Widget _buildPill(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF475569)),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155),
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

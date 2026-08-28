// lib/features/core/map_picker_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_compass/flutter_compass.dart';

class MapPickResult {
  final double lat;
  final double lng;
  final String address;
  final String mode; // 'pickup' | 'drop'

  MapPickResult({
    required this.lat,
    required this.lng,
    required this.address,
    required this.mode,
  });

  Map<String, dynamic> toMap() => {
    'lat': lat,
    'lng': lng,
    'address': address,
    'mode': mode,
  };
}

class MapPickerScreen extends StatefulWidget {
  final String mode; // 'pickup' or 'drop'
  final LatLng? initialCenter;

  /// Optional: handle the confirmed result without awaiting Navigator
  final ValueChanged<MapPickResult>? onConfirm;

  const MapPickerScreen({
    super.key,
    required this.mode,
    this.initialCenter,
    this.onConfirm,
  });

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen>
    with TickerProviderStateMixin {
  final Completer<GoogleMapController> _controllerCompleter = Completer();
  GoogleMapController? _mapController;
  final TextEditingController _searchController = TextEditingController();
  final Duration _debounceDuration = const Duration(milliseconds: 500);

  LatLng? _selected;
  LatLng? _userPos;
  String? _address;
  bool _busy = false;
  bool _mapReady = false;

  // Compass / rotation
  double _mapRotation = 0; // map rotation in degrees
  double _deviceHeading = 0; // device compass heading in degrees
  bool _followHeading = false; // “follow heading” mode

  // Streams & timers
  Timer? _debounce;
  StreamSubscription<CompassEvent>? _compassSub;

  // UI
  late final AnimationController _fabAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  static const LatLng _accra = LatLng(5.6037, -0.1870);

  @override
  void initState() {
    super.initState();

    // Keep SearchBar trailing icons reactive
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });

    // Start compass stream
    _compassSub = FlutterCompass.events?.listen((event) {
      final h = (event.heading ?? 0).toDouble();
      if (!mounted) return;
      setState(() => _deviceHeading = h);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(() {});
    _searchController.dispose();
    _compassSub?.cancel();
    _fabAnim.dispose();
    super.dispose();
  }

  // ——————————————————— Helpers ———————————————————

  Future<bool> _ensureLocationReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _toast('Please enable Location Services');
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _toast('Location permission denied');
      return false;
    }
    return true;
  }

  Future<void> _moveToUser({bool alsoSelect = false}) async {
    try {
      final ok = await _ensureLocationReady();
      if (!ok) return;

      final pos = await Geolocator.getCurrentPosition();
      final center = LatLng(pos.latitude, pos.longitude);

      if (_mapController != null) {
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(center, 15),
        );
      }
      if (!mounted) return;

      setState(() => _userPos = center);
      if (alsoSelect) {
        setState(() => _selected = center);
        await _reverseGeocode(center);
      }
    } catch (e) {
      debugPrint('Error moving to user location: $e');
      _toast('Couldn’t get your location');
    }
  }

  Future<void> _reverseGeocode(LatLng latLng) async {
    setState(() {
      _busy = true;
      _address = null;
    });

    try {
      final placemarks = await placemarkFromCoordinates(
        latLng.latitude,
        latLng.longitude,
      );

      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final parts =
            <String?>[
                  p.street,
                  p.locality,
                  p.subAdministrativeArea,
                  p.administrativeArea,
                  p.country,
                ]
                .where((e) => e != null && e.trim().isNotEmpty)
                .cast<String>()
                .toList();

        if (mounted) setState(() => _address = parts.join(', '));
      } else {
        if (mounted) setState(() => _address = 'Unknown place');
      }
    } catch (_) {
      if (mounted) setState(() => _address = 'Unknown place');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchAddress(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    try {
      final locations = await locationFromAddress(q);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        final newLatLng = LatLng(loc.latitude, loc.longitude);
        if (_mapController != null) {
          await _mapController!.animateCamera(
            CameraUpdate.newLatLngZoom(newLatLng, 14),
          );
        }
        setState(() => _selected = newLatLng);
        await _reverseGeocode(newLatLng);
      } else {
        _toast('No results found');
      }
    } catch (e) {
      debugPrint('Error searching address: $e');
      _toast('Could not find location');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onTap(LatLng latLng) {
    HapticFeedback.lightImpact();
    setState(() => _selected = latLng);

    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () => _reverseGeocode(latLng));
  }

  Future<MapPickResult?> _buildResultEnsuringAddress() async {
    if (_selected == null) return null;

    // If address hasn’t resolved yet, resolve before returning
    if (_address == null || _address!.isEmpty) {
      await _reverseGeocode(_selected!);
    }
    final addr = _address ?? 'Unnamed location';

    return MapPickResult(
      lat: _selected!.latitude,
      lng: _selected!.longitude,
      address: addr,
      mode: widget.mode,
    );
  }

  /// Called when confirming location selection.
  Future<void> _confirmFromSheet() async {
    final result = await _buildResultEnsuringAddress();
    if (result == null) {
      _toast('Tap the map to choose a location');
      return;
    }

    widget.onConfirm?.call(result);

    if (mounted) {
      Navigator.of(context).pop(result.toMap());
    }
  }

  /// For flows that want to confirm without the sheet open.
  // ignore: unused_element
  Future<void> _confirmDirect() async {
    final result = await _buildResultEnsuringAddress();
    if (result == null) {
      _toast('Tap the map to choose a location');
      return;
    }
    widget.onConfirm?.call(result);
    if (mounted) Navigator.of(context).pop(result.toMap());
  }

  Future<void> _useCurrentAndConfirm() async {
    await _moveToUser(alsoSelect: true);
    if (!mounted) return;
    // If sheet is open, follow the sheet path; if not, direct
    await _confirmFromSheet();
  }

  void _zoomIn() {
    _mapController?.animateCamera(CameraUpdate.zoomIn());
  }

  void _zoomOut() {
    _mapController?.animateCamera(CameraUpdate.zoomOut());
  }

  void _toggleFollowHeading(bool follow) {
    setState(() => _followHeading = follow);
    if (follow && _mapController != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _selected ?? _userPos ?? _accra,
            zoom: 14,
            bearing: _deviceHeading,
          ),
        ),
      );
    }
  }

  void _resetNorthUp() {
    _mapController?.animateCamera(CameraUpdate.newCameraPosition(
      CameraPosition(
        target: _selected ?? _userPos ?? _accra,
        zoom: 14,
        bearing: 0,
      ),
    ));
    setState(() {
      _mapRotation = 0;
      _followHeading = false;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ——————————————————— UI ———————————————————

  Widget _buildFlutterMap(LatLng start) {
    final modeHue = widget.mode == 'drop'
        ? BitmapDescriptor.hueViolet
        : BitmapDescriptor.hueAzure;

    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: start,
        zoom: 14,
      ),
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: true,
      mapToolbarEnabled: false,
      onMapCreated: (GoogleMapController controller) async {
        if (!_controllerCompleter.isCompleted) {
          _controllerCompleter.complete(controller);
        }
        _mapController = controller;
        if (mounted) setState(() => _mapReady = true);
        _fabAnim.forward();
        await _moveToUser();
      },
      onTap: (LatLng latLng) => _onTap(latLng),
      markers: {
        if (_selected != null)
          Marker(
            markerId: const MarkerId('selected_pin'),
            position: _selected!,
            icon: BitmapDescriptor.defaultMarkerWithHue(modeHue),
            infoWindow: InfoWindow(
              title: widget.mode == 'drop' ? 'Drop-off Location' : 'Pickup Location',
              snippet: _address ?? 'Selected location',
            ),
          ),
      },
    );
  }

  // ---- MAP TOP SEARCH HEADER ---------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  Widget _buildTopBar(BuildContext context) {
    final isDrop = widget.mode == 'drop';
    final modeLabel = isDrop ? 'Drop-off' : 'Pick-up';
    final modeColor = isDrop ? const Color(0xFF4F46E5) : const Color(0xFF2563EB);
    final modeBg = isDrop ? const Color(0xFFEEF2FF) : const Color(0xFFEFF6FF);

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Circular Back Button
              Material(
                color: const Color(0xFFF1F5F9),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded, size: 20, color: Color(0xFF334155)),
                ),
              ),
              const SizedBox(width: 8),

              // Search Field
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onSubmitted: _searchAddress,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                  decoration: InputDecoration(
                    hintText: 'Search location or landmark...',
                    hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8), fontWeight: FontWeight.normal),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF64748B)),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            child: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF94A3B8)),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Mode Pill Tag
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: modeBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: modeColor.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isDrop ? Icons.flag_rounded : Icons.my_location_rounded,
                      size: 14,
                      color: modeColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      modeLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: modeColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- MAP CONTROLS SIDEBAR ----------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  Widget _buildCompassAndZoom(BuildContext context) {
    return Positioned(
      right: 16,
      top: 110,
      child: FadeTransition(
        opacity: _fabAnim,
        child: Column(
          children: [
            // Recenter on me button
            Material(
              elevation: 4,
              shadowColor: Colors.black26,
              shape: const CircleBorder(),
              color: Colors.white,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _moveToUser(alsoSelect: true),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.my_location_rounded, color: Color(0xFF2563EB), size: 22),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Compass / Rotation control
            Material(
              elevation: 4,
              shadowColor: Colors.black26,
              shape: const CircleBorder(),
              color: Colors.white,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _toggleFollowHeading(!_followHeading),
                onLongPress: _resetNorthUp,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _followHeading ? const Color(0xFF2563EB) : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Transform.rotate(
                    angle: -_mapRotation * math.pi / 180.0,
                    child: Icon(
                      Icons.navigation_rounded,
                      size: 22,
                      color: _followHeading ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Unified Zoom Stack Container
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  IconButton(
                    tooltip: 'Zoom in',
                    onPressed: _zoomIn,
                    icon: const Icon(Icons.add_rounded, size: 20, color: Color(0xFF334155)),
                  ),
                  Container(width: 24, height: 1, color: const Color(0xFFE2E8F0)),
                  IconButton(
                    tooltip: 'Zoom out',
                    onPressed: _zoomOut,
                    icon: const Icon(Icons.remove_rounded, size: 20, color: Color(0xFF334155)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- BOTTOM CONFIRMATION OVERLAY ----------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  Widget _buildBottomOverlay(BuildContext context) {
    final isDrop = widget.mode == 'drop';
    final primaryColor = isDrop ? const Color(0xFF4F46E5) : const Color(0xFF2563EB);

    final addressText = (_selected == null)
        ? (_mapReady ? 'Tap anywhere on the map to pick a location' : 'Loading map...')
        : (_busy
              ? 'Resolving address...'
              : (_address?.isNotEmpty == true ? _address! : 'Selected coordinates (${_selected!.latitude.toStringAsFixed(4)}, ${_selected!.longitude.toStringAsFixed(4)})'));

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: FadeTransition(
        opacity: _fabAnim,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isDrop ? Icons.flag_rounded : Icons.location_on_rounded,
                      color: primaryColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isDrop ? 'Selected Drop-off Spot' : 'Selected Pick-up Spot',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          addressText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_busy)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: primaryColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _busy ? null : _confirmFromSheet,
                      icon: const Icon(Icons.check_circle_rounded, size: 18),
                      label: const Text(
                        'Confirm Location',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: const Color(0xFF334155),
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _busy ? null : _useCurrentAndConfirm,
                      icon: const Icon(Icons.my_location_rounded, size: 16),
                      label: const Text(
                        'Current',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
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

  @override
  Widget build(BuildContext context) {
    final start = widget.initialCenter ?? _accra;

    return Scaffold(
      body: Stack(
        children: [
          _buildFlutterMap(start),
          _buildTopBar(context),
          _buildCompassAndZoom(context),
          _buildBottomOverlay(context),
          if (!_mapReady)
            const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}

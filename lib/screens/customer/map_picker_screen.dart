// lib/features/core/map_picker_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
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
  final MapController _mapController = MapController();
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
  StreamSubscription? _mapEventsSub;
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
      if (_mapReady && _followHeading) {
        _mapController.rotate(h);
        setState(() => _mapRotation = h);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(() {});
    _searchController.dispose();
    _mapEventsSub?.cancel();
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

      _mapController.move(center, 15);
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
        _mapController.move(newLatLng, 14);
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
    _showConfirmSheet();
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

  /// Called when confirming from the **sheet**. We must close the sheet first,
  /// then pop the page with the result so the caller receives it.
  Future<void> _confirmFromSheet() async {
    final result = await _buildResultEnsuringAddress();
    if (result == null) {
      _toast('Tap the map to choose a location');
      return;
    }

    // 1) Close the sheet
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(); // closes the bottom sheet
    }

    // Small delay to avoid pop-race visual jank
    await Future.delayed(const Duration(milliseconds: 120));

    // 2) Notify callback (optional)
    widget.onConfirm?.call(result);

    // 3) Pop the **page** with the payload (Map) for legacy callers
    if (mounted) {
      Navigator.of(context).maybePop(result.toMap());
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
    final cam = _mapController.camera;
    _mapController.move(cam.center, cam.zoom + 1);
  }

  void _zoomOut() {
    final cam = _mapController.camera;
    _mapController.move(cam.center, cam.zoom - 1);
  }

  void _attachMapEventsListener() {
    _mapEventsSub?.cancel();
    _mapEventsSub = _mapController.mapEventStream.listen((evt) {
      final rot = evt.camera.rotation; // degrees
      if (rot != _mapRotation) {
        setState(() => _mapRotation = rot);
      }
    });
  }

  void _toggleFollowHeading(bool follow) {
    setState(() => _followHeading = follow);
    if (follow) {
      _mapController.rotate(_deviceHeading);
      setState(() => _mapRotation = _deviceHeading);
    }
  }

  void _resetNorthUp() {
    _mapController.rotate(0);
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
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: start,
        initialZoom: 12,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all, // includes rotate, pinchZoom, drag, etc.
        ),
        onTap: (tapPos, point) => _onTap(point),
        onMapReady: () async {
          if (mounted) setState(() => _mapReady = true);
          _fabAnim.forward();
          _attachMapEventsListener();
          await _moveToUser(); // center on user when ready
        },
      ),
      children: [
        // OSM tiles
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.cargomate',
          maxZoom: 19,
        ),

        const RichAttributionWidget(
          attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
        ),

        // Markers
        MarkerLayer(
          markers: [
            if (_userPos != null)
              Marker(
                point: _userPos!,
                width: 48,
                height: 48,
                child: Icon(
                  Icons.radio_button_checked,
                  size: 28,
                  color: Colors.blue,
                ),
              ),
            if (_selected != null)
              Marker(
                point: _selected!,
                width: 52,
                height: 52,
                child: const Icon(Icons.place, size: 46, color: Colors.red),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final modeLabel = widget.mode == 'drop' ? 'Drop-off' : 'Pick-up';
    final modeIcon = widget.mode == 'drop' ? Icons.flag : Icons.place;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: [
            // Filled tonal back button
            IconButton.filledTonal(
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 8),
            // Material 3 SearchBar
            Expanded(
              child: SearchBar(
                controller: _searchController,
                hintText: 'Search address or landmark…',
                elevation: const WidgetStatePropertyAll(2),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12),
                ),
                trailing: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close),
                    ),
                  IconButton(
                    tooltip: 'Search',
                    onPressed: () => _searchAddress(_searchController.text),
                    icon: const Icon(Icons.search),
                  ),
                ],
                onSubmitted: _searchAddress,
                // leading: const Icon(Icons.search),
              ),
            ),
            const SizedBox(width: 8),
            // Mode chip
            FilterChip(
              label: Text(modeLabel),
              selected: true,
              onSelected: (_) {},
              avatar: Icon(modeIcon),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompassAndZoom(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Positioned(
      right: 12,
      top: 120,
      child: FadeTransition(
        opacity: _fabAnim,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Segmented compass mode (North-up vs Follow)
            Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(100),
              color: cs.surface,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.explore),
                      label: Text('North'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.explore_off),
                      label: Text('Follow'),
                    ),
                  ],
                  selected: {_followHeading},
                  onSelectionChanged: (s) {
                    final v = s.first;
                    _toggleFollowHeading(v);
                    HapticFeedback.selectionClick();
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Round compass with tap/long-press actions
            Tooltip(
              message: _followHeading
                  ? 'Following heading • Long-press to reset North-up'
                  : 'North-up • Tap to follow heading',
              child: InkWell(
                onTap: () => _toggleFollowHeading(!_followHeading),
                onLongPress: _resetNorthUp,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                    border: Border.all(
                      color: _followHeading ? cs.primary : cs.outlineVariant,
                      width: 2,
                    ),
                  ),
                  child: Transform.rotate(
                    angle: -_mapRotation * math.pi / 180.0,
                    child: Icon(
                      Icons.navigation,
                      color: _followHeading ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Zoom controls (M3 FABs)
            Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'zoom_in',
                  tooltip: 'Zoom in',
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zoom_out',
                  tooltip: 'Zoom out',
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'recenter',
                  tooltip: 'Recenter on me',
                  onPressed: _moveToUser,
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showConfirmSheet() {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: false,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final textTheme = Theme.of(ctx).textTheme;

        final message = (_selected == null)
            ? (_mapReady ? 'Tap the map to select a location' : 'Loading map…')
            : (_busy
                  ? 'Resolving address…'
                  : (_address?.isNotEmpty == true
                        ? _address!
                        : 'Selected location'));

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Icon(
                    widget.mode == 'drop' ? Icons.flag : Icons.place,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  widget.mode == 'drop'
                      ? 'Confirm drop-off'
                      : 'Confirm pick-up',
                  style: textTheme.titleMedium,
                ),
                subtitle: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    message,
                    key: ValueKey(message),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                trailing: _busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _confirmFromSheet,
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Use selected'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : _useCurrentAndConfirm,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Use current'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : _resetNorthUp,
                  icon: const Icon(Icons.explore),
                  label: const Text('Reset north-up'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.initialCenter ?? _accra;

    return Scaffold(
      // Material 3 defaults are enabled by ThemeData(useMaterial3: true)
      body: Stack(
        children: [
          _buildFlutterMap(start),
          _buildTopBar(context),
          _buildCompassAndZoom(context),
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
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FadeTransition(
        opacity: _fabAnim,
        child: FloatingActionButton.extended(
          heroTag: 'confirm_fab',
          onPressed: () {
            if (_selected == null) {
              _toast('Tap the map to choose a location');
              return;
            }
            _showConfirmSheet();
          },
          icon: const Icon(Icons.check),
          label: const Text('Confirm location'),
        ),
      ),
    );
  }
}

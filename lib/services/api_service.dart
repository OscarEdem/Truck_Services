// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter App - High-Performance Go REST Gateway & WebSockets API Service
// ====================================================================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cargomate_v3/services/prefs.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:url_launcher/url_launcher.dart';

class ApiService {
  static final ApiService I = ApiService._();
  ApiService._();

  // Resolves Base URL from .env or defaults to Android emulator (10.0.2.2) / localhost
  String get baseUrl {
    final envUrl = dotenv.env['API_BASE_URL'];
    if (envUrl != null && envUrl.isNotEmpty) {
      return envUrl;
    }
    return 'http://10.0.2.2:8080/api';
  }

  Future<Map<String, String>> _getHeaders({bool requireAuth = true}) async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    var token = await Prefs.I.getToken();
    if (token == null || token.isEmpty) {
      token = await FirebaseAuth.instance.currentUser?.getIdToken();
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  // ----------------------------------------------------------------------------------
  // 1. Authentication & Firebase Token Validation
  // ----------------------------------------------------------------------------------

  /// Exchanges Firebase ID Token (JWT) for CargoMate Backend System Token
  Future<Map<String, dynamic>> firebaseLogin({
    required String firebaseToken,
    required String phone,
    String? role,
  }) async {
    final url = Uri.parse('$baseUrl/auth/firebase-login');
    final response = await http.post(
      url,
      headers: await _getHeaders(requireAuth: false),
      body: jsonEncode({
        'firebase_token': firebaseToken,
        'phone': phone,
        if (role != null && role.isNotEmpty) 'role': role,
      }),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['token'] as String?;
      if (token != null) {
        await Prefs.I.setToken(token);
      }
      return data;
    } else {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'Firebase authentication failed on backend gateway');
    }
  }

  /// Registers a new user profile on Go REST API gateway
  Future<Map<String, dynamic>> register({
    required String phone,
    required String fullName,
    required String role,
    String? email,
    String? avatarUrl,
    String? nationalId,
    String? licenseNumber,
    String? driverSelfieUrl,
    List<String>? vehiclePhotos,
    String? vehicleType,
    String? vehicleModel,
    String? licensePlate,
  }) async {
    final url = Uri.parse('$baseUrl/auth/register');
    final sanitizedRole = (role.toLowerCase().contains('driver') || role.toLowerCase().contains('bike'))
        ? 'driver'
        : 'customer';

    final cleanPhoneDigits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    final defaultAvatar = 'https://api.dicebear.com/7.x/adventurer/png?seed=${cleanPhoneDigits.isNotEmpty ? cleanPhoneDigits : "user"}';
    final cleanAvatar = (avatarUrl != null && avatarUrl.isNotEmpty) ? avatarUrl : defaultAvatar;

    final body = <String, dynamic>{
      'phone': phone,
      'full_name': fullName,
      'role': sanitizedRole,
      'avatar_url': cleanAvatar,
      if (email != null && email.isNotEmpty) 'email': email,
      if (nationalId != null && nationalId.isNotEmpty) 'national_id': nationalId,
      if (licenseNumber != null && licenseNumber.isNotEmpty) 'license_number': licenseNumber,
      if (driverSelfieUrl != null && driverSelfieUrl.isNotEmpty) 'driver_selfie_url': driverSelfieUrl,
      if (vehiclePhotos != null) 'vehicle_photos': vehiclePhotos,
      if (vehicleType != null && vehicleType.isNotEmpty) 'vehicle_type': vehicleType,
      if (vehicleModel != null && vehicleModel.isNotEmpty) 'vehicle_model': vehicleModel,
      if (licensePlate != null && licensePlate.isNotEmpty) 'license_plate': licensePlate,
    };

    final response = await http.post(
      url,
      headers: await _getHeaders(requireAuth: false),
      body: jsonEncode(body),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      final errorStr = response.body;
      if (errorStr.contains('users_phone_key') || errorStr.contains('duplicate key')) {
        try {
          return await updateMe(body);
        } catch (_) {}
      }
      try {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Registration failed');
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Registration failed: ${response.statusCode}');
      }
    }
  }

  /// Fetches active user profile and system metadata
  Future<Map<String, dynamic>> getMe() async {
    final url = Uri.parse('$baseUrl/users/me');
    final response = await http.get(url, headers: await _getHeaders());

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to fetch user profile: ${response.statusCode}');
    }
  }

  /// Updates active user profile details
  Future<Map<String, dynamic>> updateMe(Map<String, dynamic> updateData) async {
    final url = Uri.parse('$baseUrl/users/me');
    final map = Map<String, dynamic>.from(updateData);
    if (map.containsKey('role') && map['role'] is String) {
      final r = (map['role'] as String).toLowerCase();
      map['role'] = (r.contains('driver') || r.contains('bike')) ? 'driver' : 'customer';
    }

    final response = await http.put(
      url,
      headers: await _getHeaders(),
      body: jsonEncode(map),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to update profile');
    }
  }

  /// Generates an S3 presigned upload URL for user assets (avatar, selfie, vehicle photos)                          #*eddiere
  Future<Map<String, dynamic>> getPresignedUrl({
    required String fileType,
    required String purpose, // "avatar", "selfie", "vehicle"
  }) async {
    final url = Uri.parse('$baseUrl/assets/presigned-url');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'file_type': fileType,
        'purpose': purpose,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to generate presigned upload URL: ${response.statusCode}');
    }
  }

  /// Uploads binary asset bytes to presigned URL and returns public URL
  Future<String> uploadAssetFile(Uint8List bytes, String filename, String purpose) async {
    final ext = filename.split('.').last.toLowerCase();
    final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';
    
    final res = await getPresignedUrl(fileType: mime, purpose: purpose);
    final uploadUrl = res['upload_url'] as String?;
    final publicUrl = res['public_url'] as String?;

    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception('Presigned upload URL is empty');
    }

    // Preserve + characters in Base64 URL signature by encoding as %2B for Dart HTTP client
    final safeUploadUrl = uploadUrl.replaceAll('+', '%2B');

    final putRes = await http.put(
      Uri.parse(safeUploadUrl),
      headers: {'Content-Type': mime},
      body: bytes,
    );

    if (putRes.statusCode == 200 || putRes.statusCode == 201) {
      return (publicUrl != null && publicUrl.isNotEmpty) ? publicUrl : uploadUrl;
    } else {
      debugPrint('[GCS_UPLOAD_WARNING] GCS Upload PUT returned ${putRes.statusCode}: ${putRes.body}');
      // Fallback to Base64 Data URI in local dev mode when GCP service account key is unconfigured
      final base64Str = base64Encode(bytes);
      return 'data:$mime;base64,$base64Str';
    }
  }

  // ----------------------------------------------------------------------------------
  // 2. Deliveries & Estimation Services
  // ----------------------------------------------------------------------------------

  /// Computes shipping estimate based on pickup/dropoff coordinates
  Future<Map<String, dynamic>> getEstimate({
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    String? vehicleType,
    String? promoCode,
  }) async {
    final url = Uri.parse('$baseUrl/deliveries/estimate');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'pickup_latitude': pickupLat,
        'pickup_longitude': pickupLng,
        'dropoff_latitude': dropoffLat,
        'dropoff_longitude': dropoffLng,
        'vehicle_type': vehicleType ?? 'standard',
        'promo_code': promoCode ?? '',
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to compute delivery estimate');
    }
  }

  /// Creates a new delivery order
  Future<Map<String, dynamic>> createDelivery(Map<String, dynamic> payload) async {
    final url = Uri.parse('$baseUrl/deliveries');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode(payload),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to create delivery order');
    }
  }

  /// Lists historic or active deliveries for the user per OpenAPI 3.0.0 spec
  Future<List<dynamic>> listDeliveries({
    String? userId,
    String? role,
    String? filterStatus,
  }) async {
    final savedRole = await Prefs.I.getRole();
    final effectiveRole = (role ?? savedRole ?? 'customer').toLowerCase();

    String? effectiveUserId = userId;
    if (effectiveUserId == null || effectiveUserId.isEmpty) {
      try {
        final me = await getMe();
        final userObj = (me['user'] is Map) ? me['user'] as Map<String, dynamic> : me;
        effectiveUserId = (userObj['id'] ?? userObj['user_id'] ?? '').toString();
      } catch (_) {}
    }
    if (effectiveUserId == null || effectiveUserId.isEmpty) {
      effectiveUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
    }

    final queryParams = <String, String>{
      if (effectiveUserId.isNotEmpty) 'user_id': effectiveUserId,
      'role': effectiveRole.contains('driver') || effectiveRole.contains('bike') ? 'driver' : 'customer',
      if (filterStatus != null && filterStatus.isNotEmpty) 'filter_status': filterStatus,
    };

    final url = Uri.parse('$baseUrl/deliveries').replace(queryParameters: queryParams);
    final response = await http.get(url, headers: await _getHeaders());

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map && data.containsKey('deliveries')) {
        final rawList = data['deliveries'];
        if (rawList is List) {
          return rawList;
        }
        return [];
      }
      if (data is List) {
        return data;
      }
      return [];
    } else {
      throw Exception('Failed to fetch deliveries list');
    }
  }

  String _buildWsUrl(String path) {
    var raw = baseUrl.trim();
    if (raw.startsWith('https://')) {
      raw = 'wss://${raw.substring(8)}';
    } else if (raw.startsWith('http://')) {
      raw = 'ws://${raw.substring(7)}';
    }
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$raw$cleanPath';
  }

  /// Fetches a single delivery order by ID
  Future<Map<String, dynamic>?> getDeliveryById(String deliveryId) async {
    try {
      final url = Uri.parse('$baseUrl/deliveries/$deliveryId');
      final response = await http.get(url, headers: await _getHeaders());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          return data.containsKey('delivery')
              ? Map<String, dynamic>.from(data['delivery'] as Map)
              : data;
        }
      }
    } catch (_) {}

    // Fallback: lookup in user deliveries list
    try {
      final list = await listDeliveries(role: 'driver');
      for (final item in list) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final id = (map['id'] ?? map['delivery_id'])?.toString();
          if (id == deliveryId) return map;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Requests pre-signed Google Cloud Storage (GCS) upload URL for POD photos
  Future<Map<String, dynamic>> getPODUploadURL(String deliveryId) async {
    final url = Uri.parse('$baseUrl/deliveries/$deliveryId/pod-upload-url');
    final response = await http.post(url, headers: await _getHeaders());

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to generate pre-signed upload URL');
    }
  }

  // ----------------------------------------------------------------------------------
  // 3. Driver Real-Time Telemetry & Operations
  // ----------------------------------------------------------------------------------

  WebSocketChannel? _driverWsChannel;

  /// Connects WebSocket stream for real-time driver GPS telematics
  void startLocationWebSocket(String driverId) {
    try {
      _driverWsChannel?.sink.close();
      final wsUri = Uri.parse(_buildWsUrl('/driver/ws?driver_id=$driverId'));
      _driverWsChannel = WebSocketChannel.connect(wsUri);
      debugPrint('[WS_LOCATION] Driver WebSocket stream connected: $wsUri');
    } catch (e) {
      debugPrint('[WS_LOCATION] Driver WebSocket connection error: $e');
    }
  }

  /// Sends live GPS position packet over active WebSocket stream
  void sendLocationWebSocketPacket({
    required String driverId,
    required double latitude,
    required double longitude,
    double heading = 0.0,
    double speed = 0.0,
  }) {
    if (_driverWsChannel == null) {
      startLocationWebSocket(driverId);
    }
    try {
      final packet = jsonEncode({
        'driver_id': driverId,
        'latitude': latitude,
        'longitude': longitude,
        'heading': heading,
        'speed': speed,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _driverWsChannel?.sink.add(packet);
    } catch (e) {
      debugPrint('[WS_LOCATION] Error sending WS packet: $e');
    }
  }

  /// Stops driver WebSocket location stream
  void stopLocationWebSocket() {
    try {
      _driverWsChannel?.sink.close();
      _driverWsChannel = null;
    } catch (_) {}
  }

  /// Listens to live driver location WebSocket stream for a specific delivery order
  Stream<Map<String, dynamic>> subscribeDeliveryLocationStream(String deliveryId) {
    final controller = StreamController<Map<String, dynamic>>.broadcast();
    try {
      final wsUri = Uri.parse(_buildWsUrl('/deliveries/$deliveryId/track/ws'));
      final channel = WebSocketChannel.connect(wsUri);

      channel.stream.listen((data) {
        try {
          final decoded = jsonDecode(data.toString()) as Map<String, dynamic>;
          controller.add(decoded);
        } catch (_) {}
      }, onError: (e) {
        debugPrint('[WS_CUSTOMER] Location stream error: $e');
      }, onDone: () {
        controller.close();
      });

      controller.onCancel = () {
        channel.sink.close();
      };
    } catch (e) {
      debugPrint('[WS_CUSTOMER] Connection failed: $e');
    }
    return controller.stream;
  }

  /// REST API Fallback to fetch live driver GPS coordinates
  Future<Map<String, dynamic>?> getDriverLocation(String driverId) async {
    try {
      final url = Uri.parse('$baseUrl/driver/$driverId/location');
      final response = await http.get(url, headers: await _getHeaders());
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Opens native Google Maps Turn-by-Turn Driving Navigation
  Future<void> launchGoogleMapsNavigation({
    required double destinationLat,
    required double destinationLng,
    String? destinationName,
  }) async {
    final nameEncoded = Uri.encodeComponent(destinationName ?? 'Destination');
    // 1. Try Android Native Intent Scheme (opens Google Maps directly in turn-by-turn driving mode)
    final androidUri = Uri.parse('google.navigation:q=$destinationLat,$destinationLng&mode=d');
    // 2. Web / Universal Fallback Scheme
    final universalUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$destinationLat,$destinationLng&destination_place_name=$nameEncoded&travelmode=driving',
    );

    try {
      if (await canLaunchUrl(androidUri)) {
        await launchUrl(androidUri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}

    try {
      if (await canLaunchUrl(universalUri)) {
        await launchUrl(universalUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[NAVIGATION] Could not launch Google Maps: $e');
    }
  }

  /// Ingests driver coordinates into Redis cache (<1ms response)
  Future<void> updateDriverGPS({
    required double latitude,
    required double longitude,
    double heading = 0.0,
    double speed = 0.0,
  }) async {
    final url = Uri.parse('$baseUrl/driver/gps');
    final driverId = FirebaseAuth.instance.currentUser?.uid ?? '';

    // Send high-frequency packet over WebSocket stream first
    sendLocationWebSocketPacket(
      driverId: driverId,
      latitude: latitude,
      longitude: longitude,
      heading: heading,
      speed: speed,
    );

    await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'driver_id': driverId,
        'latitude': latitude,
        'longitude': longitude,
        'heading': heading,
        'speed': speed,
      }),
    );
  }

  /// Accepts an available delivery job with strict PostgreSQL row-level locks
  Future<Map<String, dynamic>> acceptJob(String deliveryId) async {
    final url = Uri.parse('$baseUrl/driver/accept');
    final driverId = FirebaseAuth.instance.currentUser?.uid ?? '';
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'delivery_id': deliveryId,
        'driver_id': driverId,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'Job already accepted by another driver');
    }
  }

  /// Updates delivery status ('picked_up', 'in_transit', 'delivered')
  Future<Map<String, dynamic>> updateDeliveryStatus({
    required String deliveryId,
    required String status,
    String? podProofURL,
  }) async {
    final url = Uri.parse('$baseUrl/driver/status');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'delivery_id': deliveryId,
        'status': status,
        'pod_proof_url': podProofURL ?? '',
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to update delivery status');
    }
  }

  // --------------------------------------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere
  // 4. OpenAPI Spec Extensions: Auth Session, Chat, Reviews, Payments & Promos
  // --------------------------------------------------------------------------------------------------------------------                                                                                                                                                                                #*eddiere

  /// Invalidates active user session on Redis blacklist
  Future<void> logout() async {
    final url = Uri.parse('$baseUrl/auth/logout');
    await http.post(url, headers: await _getHeaders());
    await Prefs.I.removeToken();
  }

  /// Registers device FCM token for push notifications
  Future<void> registerFcmToken(String fcmToken, {String deviceType = 'android'}) async {
    final url = Uri.parse('$baseUrl/users/fcm-token');
    await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'fcm_token': fcmToken,
        'device_type': deviceType,
      }),
    );
  }

  /// Fetches single delivery detail
  Future<Map<String, dynamic>> getDeliveryDetail(String id) async {
    final url = Uri.parse('$baseUrl/deliveries/$id');
    final response = await http.get(url, headers: await _getHeaders());
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to load delivery details');
  }

  /// Fetches delivery audit logs timeline
  Future<List<dynamic>> getDeliveryLogs(String id) async {
    final url = Uri.parse('$baseUrl/deliveries/$id/logs');
    final response = await http.get(url, headers: await _getHeaders());
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data is Map && data['logs'] is List) ? data['logs'] as List<dynamic> : (data is List ? data : []);
    }
    throw Exception('Failed to load delivery logs');
  }

  /// Sends in-app chat message for a delivery order
  Future<Map<String, dynamic>> sendChatMessage(String deliveryId, String message) async {
    final url = Uri.parse('$baseUrl/deliveries/$deliveryId/chat');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({'message': message}),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to send chat message');
  }

  /// Retrieves chat message history for a delivery order
  Future<List<dynamic>> getChatMessages(String deliveryId) async {
    final url = Uri.parse('$baseUrl/deliveries/$deliveryId/chat');
    final response = await http.get(url, headers: await _getHeaders());
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data is Map && data['messages'] is List) ? data['messages'] as List<dynamic> : [];
    }
    throw Exception('Failed to fetch chat history');
  }

  /// Submits rating and review for completed delivery order
  Future<void> submitReview(String deliveryId, {required int stars, String? comments}) async {
    final url = Uri.parse('$baseUrl/deliveries/$deliveryId/review');
    await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
        'stars': stars,
        'comments': comments ?? '',
      }),
    );
  }

  /// Initializes checkout session with Paystack gateway
  Future<Map<String, dynamic>> initiatePayment(String deliveryId) async {
    final url = Uri.parse('$baseUrl/payment/initiate');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({'delivery_id': deliveryId}),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to initiate payment');
  }

  /// Verifies transaction checkout reference
  Future<Map<String, dynamic>> verifyPayment(String reference) async {
    final url = Uri.parse('$baseUrl/payment/verify');
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({'reference': reference}),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to verify payment');
  }

  /// Retrieves targeted active promotional campaigns
  Future<List<dynamic>> getActivePromos() async {
    final url = Uri.parse('$baseUrl/promos/active');
    final response = await http.get(url, headers: await _getHeaders());
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return (data is Map && data['campaigns'] is List) ? data['campaigns'] as List<dynamic> : [];
    }
    return [];
  }
}

// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter App - High-Performance Go REST Gateway & WebSockets API Service
// ====================================================================================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cargomate_v3/services/prefs.dart';

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
  }) async {
    final url = Uri.parse('$baseUrl/auth/firebase-login');
    final response = await http.post(
      url,
      headers: await _getHeaders(requireAuth: false),
      body: jsonEncode({
        'firebase_token': firebaseToken,
        'phone': phone,
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

  /// Lists historic or active deliveries for the user
  Future<List<dynamic>> listDeliveries() async {
    final url = Uri.parse('$baseUrl/deliveries');
    final response = await http.get(url, headers: await _getHeaders());

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map && data.containsKey('deliveries')) {
        return data['deliveries'] as List<dynamic>;
      }
      return data as List<dynamic>;
    } else {
      throw Exception('Failed to fetch deliveries list');
    }
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

  /// Ingests driver coordinates into Redis cache (<1ms response)
  Future<void> updateDriverGPS({
    required double latitude,
    required double longitude,
    double heading = 0.0,
    double speed = 0.0,
  }) async {
    final url = Uri.parse('$baseUrl/driver/gps');
    await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({
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
    final response = await http.post(
      url,
      headers: await _getHeaders(),
      body: jsonEncode({'delivery_id': deliveryId}),
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

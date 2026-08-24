// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter App - Paystack Payment Integration Service
// ====================================================================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:cargomate_v3/services/prefs.dart';

class NotInitializedError implements Exception {
  final String message;
  NotInitializedError(this.message);
  @override
  String toString() => 'NotInitializedError: $message';
}

class PayResult {
  final bool ok;
  final String? reference;
  final String? message;
  const PayResult({required this.ok, this.reference, this.message});
}

class VerifyResult {
  final bool ok;
  final Map<String, dynamic>? delivery;
  final dynamic raw;
  final String? error;
  const VerifyResult({required this.ok, this.delivery, this.raw, this.error});
}

class CargomatePaystack {
  static String get _base {
    final envUrl = dotenv.env['API_BASE_URL'];
    if (envUrl != null && envUrl.isNotEmpty) {
      return envUrl.endsWith('/') ? envUrl.substring(0, envUrl.length - 1) : envUrl;
    }
    return 'http://10.0.2.2:8080/api';
  }

  static String get _publicKey {
    final v = dotenv.env['PAYSTACK_PUBLIC_KEY'];
    if (v == null || v.isEmpty) {
      throw NotInitializedError('PAYSTACK_PUBLIC_KEY missing in .env');
    }
    return v;
  }

  static const String _callbackScheme = 'cargomate';
  static const String _callbackHost = 'paystack-callback';
  static String get _redirectUrl => '$_callbackScheme://$_callbackHost';

  static Future<({String authorizationUrl, String reference})> _initOnServer({
    required String email,
    required double amount,
    String currency = 'GHS',
    Map<String, dynamic>? metadata,
  }) async {
    final uri = Uri.parse('$_base/payment/initiate');
    final token = await Prefs.I.getToken();
    final headers = {
      HttpHeaders.contentTypeHeader: 'application/json',
      if (token != null && token.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $token',
    };

    final resp = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'email': email,
        'amount': amount,
        'currency': currency,
        'metadata': metadata ?? {},
        'redirect_url': _redirectUrl,
      }),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Payment initiation failed: ${resp.statusCode} ${resp.body}');
    }
    final obj = jsonDecode(resp.body) as Map<String, dynamic>;
    final authUrl = obj['authorization_url']?.toString() ?? obj['checkout_url']?.toString();
    final ref = obj['reference']?.toString();

    if (authUrl == null || ref == null) {
      throw Exception('Payment gateway missing authorization_url or reference');
    }
    return (authorizationUrl: authUrl, reference: ref);
  }

  static Future<PayResult> charge({
    required BuildContext context,
    required double amount,
    required String currency,
    String email = 'customer@example.com',
    Map<String, dynamic>? metadata,
  }) async {
    _publicKey; // sanity check

    ({String authorizationUrl, String reference})? init;
    try {
      init = await _initOnServer(
        email: email,
        amount: amount,
        currency: currency,
        metadata: metadata,
      );

      final callbackUrl = await FlutterWebAuth2.authenticate(
        url: init.authorizationUrl,
        callbackUrlScheme: _callbackScheme,
      );

      final uri = Uri.parse(callbackUrl);
      final refFromCallback =
          uri.queryParameters['reference'] ?? uri.queryParameters['trxref'];
      final reference = refFromCallback ?? init.reference;

      return PayResult(ok: true, reference: reference);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED' && init != null) {
        return PayResult(
          ok: false,
          reference: init.reference,
          message: 'CANCELED',
        );
      }
      return PayResult(ok: false, message: e.toString());
    } catch (e) {
      return PayResult(ok: false, message: e.toString());
    }
  }

  static Future<VerifyResult> verifyDelivery({
    required String reference,
    Map<String, dynamic>? deliveryDraft,
    String? deliveryId,
  }) async {
    try {
      final uri = Uri.parse('$_base/payment/verify');
      final token = await Prefs.I.getToken();
      final headers = {
        HttpHeaders.contentTypeHeader: 'application/json',
        if (token != null && token.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $token',
      };

      final resp = await http.post(
        uri,
        headers: headers,
        body: jsonEncode({
          'reference': reference,
          if (deliveryId != null) 'delivery_id': deliveryId,
          if (deliveryDraft != null) 'delivery_draft': deliveryDraft,
        }),
      );

      final body = jsonDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return VerifyResult(
          ok: true,
          delivery: (body['delivery'] as Map?)?.cast<String, dynamic>(),
          raw: body,
          error: null,
        );
      }
      return VerifyResult(
        ok: false,
        delivery: null,
        raw: body,
        error:
            body['error']?.toString() ??
            body['message']?.toString() ??
            'Verify failed (status=${resp.statusCode})',
      );
    } catch (e) {
      return VerifyResult(
        ok: false,
        delivery: null,
        raw: null,
        error: e.toString(),
      );
    }
  }
}

// ====================================================================================================================                                                                                                                                                                                #*eddiere
// CargoMate Flutter App - Paystack Payment Integration Service
// ====================================================================================================================

import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
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
    String? deliveryId,
    String? email,
    double? amount,
    String currency = 'GHS',
    Map<String, dynamic>? metadata,
  }) async {
    final uri = Uri.parse('$_base/payment/initiate');
    final token = await Prefs.I.getToken();
    final headers = {
      HttpHeaders.contentTypeHeader: 'application/json',
      if (token != null && token.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $token',
    };

    final Map<String, dynamic> body = {};
    if (deliveryId != null && deliveryId.isNotEmpty) {
      body['delivery_id'] = deliveryId;
    }
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (amount != null && amount > 0) body['amount'] = amount;
    body['currency'] = currency;
    if (metadata != null) body['metadata'] = metadata;
    body['redirect_url'] = _redirectUrl;

    final resp = await http.post(
      uri,
      headers: headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Payment initiation failed: ${resp.statusCode} ${resp.body}');
    }
    final obj = jsonDecode(resp.body) as Map<String, dynamic>;
    final authUrl = obj['checkout_url']?.toString() ?? obj['authorization_url']?.toString();
    final ref = obj['reference']?.toString();

    if (authUrl == null || ref == null) {
      throw Exception('Payment gateway missing checkout_url or reference');
    }
    return (authorizationUrl: authUrl, reference: ref);
  }

  static Future<PayResult> charge({
    required BuildContext context,
    String? deliveryId,
    double? amount,
    String currency = 'GHS',
    String? email,
    Map<String, dynamic>? metadata,
  }) async {
    _publicKey; // sanity check

    final user = FirebaseAuth.instance.currentUser;
    final String validEmail = (email != null && email.trim().isNotEmpty && email.contains('@'))
        ? email.trim()
        : ((user?.email != null && user!.email!.isNotEmpty && user.email!.contains('@'))
            ? user.email!
            : 'customer_${user?.uid ?? "app"}@cargomate.com');

    final double validAmount = (amount == null || amount <= 0) ? 1.0 : amount;

    ({String authorizationUrl, String reference})? init;
    try {
      init = await _initOnServer(
        deliveryId: deliveryId,
        email: validEmail,
        amount: validAmount,
        currency: currency,
        metadata: metadata,
      );

      final String ref = init.reference;

      // Launch Paystack checkout in web view
      try {
        final callbackUrl = await FlutterWebAuth2.authenticate(
          url: init.authorizationUrl,
          callbackUrlScheme: _callbackScheme,
        );

        final uri = Uri.parse(callbackUrl);
        final refFromCallback =
            uri.queryParameters['reference'] ?? uri.queryParameters['trxref'];
        final finalRef = refFromCallback ?? ref;

        return PayResult(ok: true, reference: finalRef);
      } on PlatformException catch (e) {
        // User closed browser view or canceled; verify if payment was settled on Paystack server anyway
        final v = await verifyDelivery(reference: ref, deliveryId: deliveryId);
        if (v.ok) {
          return PayResult(ok: true, reference: ref);
        }
        return PayResult(
          ok: false,
          reference: ref,
          message: e.code == 'CANCELED' ? 'CANCELED' : e.message,
        );
      }
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

// import 'dart:io';
// import 'package:firebase_core/firebase_core.dart';
// import 'package:firebase_messaging/firebase_messaging.dart';
// import 'package:supabase_flutter/supabase_flutter.dart';

// class PushService {
//   PushService._(); static final instance = PushService._(); final supa = Supabase.instance.client;

//   Future<void> initAndRegisterToken() async {
//     await Firebase.initializeApp();
//     final messaging = FirebaseMessaging.instance;
//     if (Platform.isIOS) { await messaging.requestPermission(alert: true, badge: true, sound: true); }
//     final token = await messaging.getToken();
//     if (token != null) {
//       final uid = supa.auth.currentUser?.id;
//       if (uid != null) { await supa.from('profiles').update({'fcm_token': token}).eq('id', uid); }
//     }
//     FirebaseMessaging.onMessage.listen((m) { /* optionally show overlay/snackbar */ });
//   }
// }

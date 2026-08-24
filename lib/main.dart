// lib/main.dart
import 'package:cargomate_v3/firebase_options.dart';
import 'package:cargomate_v3/theme/app_theme.dart';
import 'package:cargomate_v3/viewmodel/role_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
// import 'firebase_options.dart';
import 'routes/navRoutes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await dotenv.load(fileName: ".env");
  assert(dotenv.env.isNotEmpty, "dotenv.env is empty — .env not loaded?");

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RoleViewModel>(create: (_) => RoleViewModel()),
      ],
      child: const CargoMateApp(),
    ),
  );
}

class CargoMateApp extends StatelessWidget {
  const CargoMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CargoMate',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      // darkTheme: AppTheme.dark(),
      navigatorObservers: [routeObserver],
      initialRoute: NavRoutes.splash,
      routes: AppRoutes.routes,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}

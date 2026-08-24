// lib/routes/navRoutes.dart
import 'package:cargomate_v3/screens/auth/sign_in_page.dart';
import 'package:cargomate_v3/screens/auth/signup_screen.dart';
import 'package:cargomate_v3/screens/customer/delivery_review_screen.dart';
import 'package:cargomate_v3/screens/profile_screen.dart';
import 'package:flutter/material.dart';

// 🔹 Core / Auth
import 'package:cargomate_v3/screens/splash_screen.dart';
import 'package:cargomate_v3/screens/auth/otp_verify_screen.dart';
import 'package:cargomate_v3/screens/onboarding_screen.dart';

// 🔹 Customer / Driver / Features
import 'package:cargomate_v3/screens/customer/home_page.dart';
import 'package:cargomate_v3/screens/Driver/driver_home_page.dart';
import 'package:cargomate_v3/screens/customer/booking_screen.dart';
import 'package:cargomate_v3/screens/my_deliveries_screen.dart';
import 'package:cargomate_v3/screens/delivery_details_screen.dart';
import 'package:cargomate_v3/screens/customer/map_picker_screen.dart';
import 'package:cargomate_v3/screens/notifications_page.dart';
import 'package:cargomate_v3/screens/customer/schedule_page.dart';

/// -------- Route names + helpers (self-contained) --------
class NavRoutes {
  // Core / Auth
  static const String splash = '/splash';
  static const String signUpPhone = '/auth/phone';
  static const String otpVerify = '/auth/otp';
  static const String completeProfile = '/auth/complete';
  static const String signUp = '/auth/signUp';
  static const String signIn = '/auth/signIn';
  static const String onboarding = '/onboarding';

  // Homes
  static const String homePage = '/homePage';
  static const String driverHome = '/driverHome';

  // Features
  static const String book = '/book';
  static const String myDeliveries = '/myDeliveries';
  static const String deliveryDetails = '/deliveryDetails';
  static const String mapPicker = '/map-picker';
  static const String notifications = '/notifications';
  static const String schedule = '/schedule';
  static const String deliveryReview = '/deliveryreview';
  static const String profile = '/profile';

  // Aliases
  static const String deliveries = '/deliveries';
  static const String bookingLegacy = '/booking';

  /// Role-based navigation helper
  static void navigateToHome(BuildContext context, String role) {
    final target = role.toLowerCase() == 'driver' ? driverHome : homePage;
    Navigator.pushNamedAndRemoveUntil(context, target, (_) => false);
  }
}

// Global RouteObserver for RouteAware pages (analytics, etc.)
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// -------- Route table + onGenerateRoute + custom transition --------
class AppRoutes {
  /// Static routes (simple builders, no dynamic args)
  static Map<String, WidgetBuilder> get routes => <String, WidgetBuilder>{
    // Auth / Core
    NavRoutes.splash: (_) => const SplashScreen(),
    // NavRoutes.signUpPhone: (_) => const PhoneInputScreen(),
    NavRoutes.otpVerify: (_) => const OtpVerifyScreen(),
    // NavRoutes.completeProfile: (_) => const CompleteProfileScreen(),
    NavRoutes.signIn: (_) => const SignInScreen(),
    NavRoutes.signUp: (_) => const SignUpScreen(),
    NavRoutes.onboarding: (_) => const OnboardingScreen(),

    // Homes
    NavRoutes.homePage: (_) => const HomePage(),
    NavRoutes.driverHome: (_) => const DriverHomePage(),

    // Features (simple)
    NavRoutes.book: (_) => const BookingScreen(),
    NavRoutes.myDeliveries: (_) => const MyDeliveriesScreen(),
    NavRoutes.notifications: (_) => const NotificationsPage(),
    NavRoutes.schedule: (_) => const ScheduleScreen(),
    NavRoutes.profile: (_) => const ProfileScreen(),

    // Aliases
    NavRoutes.deliveries: (_) => const MyDeliveriesScreen(),
    NavRoutes.bookingLegacy: (_) => const BookingScreen(),

    // 🚫 Do NOT put NavRoutes.deliveryReview here — it needs args.
  };

  /// Dynamic routes & custom transitions
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? '';
    final uri = Uri.parse(name);
    final segs = uri.pathSegments; // handles "/delivery/123?tab=timeline"

    // ✅ Delivery Review — needs arguments from pushNamed(...)
    if (name == NavRoutes.deliveryReview) {
      return CustomRoute(
        settings: settings,
        builder: (_) => DeliveryReviewScreen.fromNamedArgs(settings.arguments),
      );
    }

    // 1) Delivery details:
    //    - support "/deliveryDetails" with arguments Map
    //    - support "/delivery/<id>" using path segment
    if (name == NavRoutes.deliveryDetails ||
        (segs.isNotEmpty && segs.first.toLowerCase() == 'delivery')) {
      Map<String, dynamic> deliveryArg = const {};
      if (settings.arguments is Map<String, dynamic>) {
        deliveryArg = settings.arguments as Map<String, dynamic>;
      } else if (segs.length >= 2) {
        final id = segs[1];
        deliveryArg = {'id': id}; // your screen can fetch by id if needed
      }

      return CustomRoute(
        settings: settings,
        builder: (_) => DeliveryDetailsScreen(delivery: deliveryArg),
      );
    }

    // 2) Map picker with optional args:
    //    - named: NavRoutes.mapPicker
    //    - dynamic: "/map-picker?mode=pickup"
    if (name == NavRoutes.mapPicker ||
        (segs.isNotEmpty && segs.first == 'map-picker')) {
      var mode = '';
      if (settings.arguments is Map) {
        final m = settings.arguments as Map;
        mode = (m['mode'] ?? '').toString();
      } else {
        mode = uri.queryParameters['mode'] ?? '';
      }
      return CustomRoute(
        settings: settings,
        builder: (_) => MapPickerScreen(mode: mode),
      );
    }

    // 3) OTP verify when called with typed args (optional)
    if (name == NavRoutes.otpVerify && settings.arguments != null) {
      return CustomRoute(
        settings: settings,
        builder: (_) => const OtpVerifyScreen(),
      );
    }

    // Unknown → let MaterialApp.onUnknownRoute handle it (404)
    return null;
  }
}

/// Simple right-to-left slide transition (Material 3 friendly)
class CustomRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;

  CustomRoute({
    required this.builder,
    super.settings,
    Duration duration = const Duration(milliseconds: 260),
  }) : super(
         transitionDuration: duration,
         reverseTransitionDuration: duration,
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           final offsetTween = Tween<Offset>(
             begin: const Offset(1, 0), // from right
             end: Offset.zero,
           ).chain(CurveTween(curve: Curves.easeOutCubic));
           return SlideTransition(
             position: animation.drive(offsetTween),
             child: child,
           );
         },
       );
}

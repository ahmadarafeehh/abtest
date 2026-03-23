import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/screens/first_time/get_started_page.dart';
import 'package:Ratedly/screens/signup/onboarding_flow.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/screens/login.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/services/debug_logger.dart';

Future<void> _logError({
  required String eventType,
  String? firebaseUid,
  String? supabaseUid,
  String? email,
  String? errorDetails,
  String? stackTrace,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': eventType,
      'firebase_uid': firebaseUid,
      'supabase_uid': supabaseUid,
      'email': email,
      'error_details': errorDetails,
      'stack_trace': stackTrace,
      'additional_data': additionalData,
    });
  } catch (_) {}
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({Key? key}) : super(key: key);

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final CountryService _countryService = CountryService();
  final AuthMethods _authMethods = AuthMethods();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = true;
  bool _usingCachedData = false;
  bool _needsMigration = false;
  bool _checkingMigration = false;
  bool _isInitializing = false;

  String? _firebaseUid;
  String? _supabaseUid;
  String? _userEmail;
  String? _userName;
  String? _photoUrl;
  bool _isMigrated = false;
  bool _onboardingComplete = false;

  static SharedPreferences? _prefs;
  static Future<SharedPreferences> get prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  late final StreamSubscription<AuthState> _authSubscription;

  @override
  void initState() {
    super.initState();
    _initializeAuth();

    _authSubscription = _supabase.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn ||
          data.event == AuthChangeEvent.tokenRefreshed) {
        if (!_isInitializing) {
          _isInitializing = true;
          _initializeAuth().whenComplete(() {
            _isInitializing = false;
          });
        }
      } else if (data.event == AuthChangeEvent.signedOut && mounted) {
        setState(() {
          _firebaseUid = null;
          _supabaseUid = null;
          _isLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  Future<void> _initializeAuth() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    final supabaseSession = _supabase.auth.currentSession;
    final firebaseUser = _auth.currentUser;

    if (supabaseSession != null) {
      await _handleSupabaseSession(supabaseSession, userProvider);
      return;
    }

    if (firebaseUser != null) {
      await _handleFirebaseUser(firebaseUser, userProvider);
      return;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleSupabaseSession(
      Session session, UserProvider userProvider) async {
    String? recordSource;
    bool found = false;
    Map<String, dynamic>? userData;
    final firebaseUser = _auth.currentUser;

    try {
      // --- STEP 1: Find by Firebase UID (migration path) ---
      if (firebaseUser != null) {
        userData = await _supabase
            .from('users')
            .select()
            .eq('uid', firebaseUser.uid)
            .maybeSingle();

        if (userData != null) {
          found = true;
          recordSource = 'firebase_uid';

          await _supabase.from('users').update({
            'supabase_uid': session.user.id,
            'migrated': true,
          }).eq('uid', firebaseUser.uid);

          await _supabase
              .from('users')
              .delete()
              .eq('supabase_uid', session.user.id)
              .neq('uid', firebaseUser.uid);

          userData = await _supabase
              .from('users')
              .select()
              .eq('uid', firebaseUser.uid)
              .maybeSingle();
        }
      }

      // --- STEP 2: Find by email (unmigrated user) ---
      if (!found && session.user.email != null) {
        final userByEmail = await _supabase
            .from('users')
            .select()
            .eq('email', session.user.email!)
            .eq('migrated', false)
            .maybeSingle();

        if (userByEmail != null) {
          found = true;
          recordSource = 'email_migration';
          userData = userByEmail;

          await _supabase.from('users').update({
            'supabase_uid': session.user.id,
            'migrated': true,
          }).eq('uid', userData!['uid']);

          await _supabase
              .from('users')
              .delete()
              .eq('supabase_uid', session.user.id)
              .neq('uid', userData!['uid']);

          userData = await _supabase
              .from('users')
              .select()
              .eq('uid', userData!['uid'])
              .maybeSingle();
        }
      }

      // --- STEP 3: Find by supabase_uid (returning Supabase user) ---
      if (!found) {
        final records = await _supabase
            .from('users')
            .select()
            .eq('supabase_uid', session.user.id);

        if (records.isNotEmpty) {
          found = true;
          recordSource = 'supabase_uid';

          if (records.length > 1) {
            Map<String, dynamic>? bestRecord;
            List<Map<String, dynamic>> others = [];
            for (var rec in records) {
              final hasData = rec['username'] != null &&
                  rec['username'].toString().isNotEmpty &&
                  rec['dateOfBirth'] != null;
              if (hasData) {
                bestRecord = rec;
              } else {
                others.add(rec);
              }
            }
            if (bestRecord == null) {
              bestRecord = records.first;
              others = records.sublist(1);
            }
            userData = bestRecord;
            for (var rec in others) {
              await _supabase.from('users').delete().eq('uid', rec['uid']);
            }
          } else {
            userData = records.first as Map<String, dynamic>;
          }
        }
      }

      // --- STEP 4: No record found — create new user ---
      if (!found) {
        recordSource = 'none_created_new';

        final newUser = {
          'uid': session.user.id,
          'email': session.user.email,
          'username': '',
          'bio': '',
          'photoUrl': 'default',
          'isPrivate': false,
          'onboardingComplete': false,
          'createdAt': DateTime.now().toIso8601String(),
          'dateOfBirth': null,
          'gender': null,
          'isVerified': false,
          'blockedUsers': <dynamic>[],
          'country': null,
          'migrated': true,
          'supabase_uid': session.user.id,
        };
        await _supabase.from('users').upsert(newUser, onConflict: 'uid');
        userData = newUser;
      }

      // Populate state from the resolved record
      _supabaseUid = session.user.id;
      _firebaseUid = userData!['uid'] as String?;
      _userEmail = userData['email'] as String? ?? session.user.email;
      _userName = userData['username'] as String?;
      _photoUrl = userData['photoUrl'] as String?;
      _isMigrated = userData['migrated'] == true;

      // Initialize UserProvider
      try {
        userProvider.initializeUser({
          'uid': _firebaseUid,
          'supabase_uid': _supabaseUid,
          'migrated': _isMigrated,
          ...userData,
        });
      } catch (e, stack) {
        await _logError(
          eventType: 'USER_PROVIDER_INIT_ERROR',
          firebaseUid: _firebaseUid,
          supabaseUid: _supabaseUid,
          email: _userEmail,
          errorDetails: e.toString(),
          stackTrace: stack.toString(),
        );
        rethrow;
      }

      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);
      _onboardingComplete = hasCompletedOnboarding;

      if (mounted) {
        setState(() {
          _onboardingComplete = hasCompletedOnboarding;
          _isLoading = false;
        });
      }

      _updateAuthCache(hasCompletedOnboarding);
      _runCountryChecks(_firebaseUid!);
    } catch (e, stack) {
      await _logError(
        eventType: 'ERROR_SUPABASE_SESSION_HANDLING',
        firebaseUid: firebaseUser?.uid,
        supabaseUid: session.user.id,
        email: session.user.email,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('SUPABASE_SESSION_HANDLING', e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleFirebaseUser(
      firebase_auth.User firebaseUser, UserProvider userProvider) async {
    _firebaseUid = firebaseUser.uid;
    _userEmail = firebaseUser.email;
    _userName = firebaseUser.displayName;
    _photoUrl = firebaseUser.photoURL;
    _isMigrated = false;

    final cachedData = await _loadCachedAuthDataInstantly();

    if (cachedData != null && mounted) {
      setState(() {
        _onboardingComplete = cachedData['onboardingComplete'] ?? false;
        _usingCachedData = true;
        _isLoading = false;
      });

      await _initializeUserProvider(userProvider);
      _verifyOnboardingInBackground();
    } else {
      if (mounted) setState(() => _isLoading = false);
      await _checkOnboardingFromDatabase(userProvider);
    }

    _checkMigrationInBackground();
    _runCountryChecks(_firebaseUid!);
  }

  Future<void> _initializeUserProvider(UserProvider userProvider) async {
    try {
      final userData = await _supabase
          .from('users')
          .select()
          .eq('uid', _firebaseUid!)
          .maybeSingle();

      if (userData != null) {
        userProvider.initializeUser(userData as Map<String, dynamic>);
      }
    } catch (e) {
      DebugLogger.logError('INIT_USER_PROVIDER', e);
    }
  }

  Future<Map<String, dynamic>?> _loadCachedAuthDataInstantly() async {
    try {
      if (_firebaseUid == null) return null;
      final prefs = await prefsInstance;
      final cachedData = prefs.getString('auth_cache_v4_$_firebaseUid');
      if (cachedData != null) {
        final data = jsonDecode(cachedData);
        final lastUpdated = data['lastUpdated'] ?? 0;
        final cacheAge = DateTime.now().millisecondsSinceEpoch - lastUpdated;
        if (cacheAge < 24 * 60 * 60 * 1000) {
          return {
            'onboardingComplete': data['onboardingComplete'] ?? false,
            'lastUpdated': lastUpdated,
          };
        }
      }
    } catch (e) {
      DebugLogger.logError('LOAD_CACHED_AUTH', e);
    }
    return null;
  }

  Future<void> _verifyOnboardingInBackground() async {
    if (_firebaseUid == null || !_usingCachedData) return;
    try {
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);
      if (hasCompletedOnboarding != _onboardingComplete && mounted) {
        setState(() => _onboardingComplete = hasCompletedOnboarding);
        _updateAuthCache(hasCompletedOnboarding);
      }
    } catch (e) {
      DebugLogger.logError('VERIFY_ONBOARDING_BG', e);
    }
  }

  Future<bool> _checkOnboardingStatus(String uid) async {
    try {
      final response = await _supabase
          .from('users')
          .select('username, dateOfBirth, gender, onboardingComplete')
          .eq('uid', uid)
          .maybeSingle();

      if (response == null) return false;

      final data = response as Map<String, dynamic>;
      return data['onboardingComplete'] == true ||
          (data['dateOfBirth'] != null &&
              data['username'] != null &&
              data['username'].toString().isNotEmpty &&
              data['gender'] != null &&
              data['gender'].toString().isNotEmpty);
    } catch (e) {
      DebugLogger.logError('CHECK_ONBOARDING_STATUS', e);
      return false;
    }
  }

  Future<void> _checkOnboardingFromDatabase(UserProvider userProvider) async {
    if (_firebaseUid == null) return;
    try {
      await _initializeUserProvider(userProvider);
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);
      if (mounted) setState(() => _onboardingComplete = hasCompletedOnboarding);
      _updateAuthCache(hasCompletedOnboarding);
    } catch (e) {
      DebugLogger.logError('CHECK_ONBOARDING_DB', e);
    }
  }

  Future<void> _checkMigrationInBackground() async {
    if (_firebaseUid == null || _checkingMigration) return;
    _checkingMigration = true;
    try {
      final migrationStatus =
          await _authMethods.getCurrentUserMigrationStatus();
      if (mounted) {
        setState(() {
          _needsMigration = migrationStatus['needs_migration'] == true;
        });
        if (_needsMigration) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) _showMigrationScreen();
        }
      }
    } catch (e) {
      DebugLogger.logError('CHECK_MIGRATION', e);
    } finally {
      _checkingMigration = false;
    }
  }

  void _runCountryChecks(String uid) {
    Future.delayed(const Duration(seconds: 3), () {
      _countryService.checkAndBackfillCountryForExistingUsers();
    });
    Future.delayed(const Duration(seconds: 5), () {
      _countryService.checkAndUpdateCountryIfNeeded();
    });
  }

  Future<void> _updateAuthCache(bool onboardingComplete) async {
    try {
      if (_firebaseUid == null) return;
      final prefs = await prefsInstance;
      await prefs.setString(
        'auth_cache_v4_$_firebaseUid',
        jsonEncode({
          'onboardingComplete': onboardingComplete,
          'lastUpdated': DateTime.now().millisecondsSinceEpoch,
          'userId': _firebaseUid,
        }),
      );
    } catch (e) {
      DebugLogger.logError('UPDATE_AUTH_CACHE', e);
    }
  }

  void _showMigrationScreen() {
    if (_firebaseUid == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => LoginScreen(
          migrationEmail: _userEmail ?? '',
          migrationUid: _firebaseUid!,
        ),
      ),
    );
  }

  void _handleOnboardingComplete() {
    if (mounted) setState(() => _onboardingComplete = true);
    _updateAuthCache(true);
  }

  @override
  Widget build(BuildContext context) {
    // =========================================================
    // DEV MODE: Set to true to skip auth and go straight to app
    // Set back to false before releasing to production
    const bool devModeBypassAuth = true;
    if (devModeBypassAuth) {
      return _DevModeLoader();
    }
    // =========================================================

    if (_isLoading) return _buildSimpleLoadingScreen();

    final bool hasUser = _firebaseUid != null || _supabaseUid != null;

    if (hasUser && _onboardingComplete && !_needsMigration) {
      return const ResponsiveLayout(mobileScreenLayout: MobileScreenLayout());
    }

    if (hasUser) {
      return OnboardingFlow(
        onComplete: _handleOnboardingComplete,
        onError: (error) =>
            DebugLogger.logError('ONBOARDING_FLOW_ERROR', error),
      );
    }

    return const GetStartedPage();
  }

  Widget _buildSimpleLoadingScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo/22.png', width: 100, height: 100),
            const SizedBox(height: 20),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// DEV MODE LOADER — loads a real user from Supabase so feed/screens work
// Replace DEV_USER_UID below with any real uid from your users table
// =============================================================================
class _DevModeLoader extends StatefulWidget {
  @override
  State<_DevModeLoader> createState() => _DevModeLoaderState();
}

class _DevModeLoaderState extends State<_DevModeLoader> {
  // ⬇️ PUT YOUR REAL USER UID HERE (copy any uid from your Supabase users table)
  static const String _devUserId = '4100c49e-6a7e-45d8-a2d2-45e70a01dba3';

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadDevUser();
  }

  Future<void> _loadDevUser() async {
    try {
      final supabase = Supabase.instance.client;
      final data = await supabase
          .from('users')
          .select()
          .eq('uid', _devUserId)
          .maybeSingle();

      if (data != null && mounted) {
        // Use addPostFrameCallback to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final userProvider =
              Provider.of<UserProvider>(context, listen: false);
          userProvider.initializeUser(Map<String, dynamic>.from(data));
          print('[DEV] Loaded dev user: ${data['username']} (${data['uid']})');
          print('[DEV] userProvider.firebaseUid = ${userProvider.firebaseUid}');
          print('[DEV] userProvider.supabaseUid = ${userProvider.supabaseUid}');
          print('[DEV] userProvider.user?.uid = ${userProvider.user?.uid}');
          if (mounted) setState(() => _loaded = true);
        });
      } else {
        print('[DEV] WARNING: No user found for uid=$_devUserId');
        if (mounted) setState(() => _loaded = true);
      }
    } catch (e) {
      print('[DEV] Error loading dev user: $e');
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF121212),
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }
    return const ResponsiveLayout(mobileScreenLayout: MobileScreenLayout());
  }
}

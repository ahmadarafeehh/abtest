import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart' as firebase_messaging;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationService {
  final firebase_messaging.FirebaseMessaging _firebaseMessaging = firebase_messaging.FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  int _getNotificationId() {
    return DateTime.now().millisecondsSinceEpoch % 2147483647;
  }

  Future<void> init() async {
    try {
      await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        criticalAlert: true,
        provisional: true,
        sound: true,
      );

      await firebase_messaging.FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );

      firebase_messaging.FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      firebase_messaging.FirebaseMessaging.onMessageOpenedApp.listen(_handleBackgroundMessage);

      await _handleTokenRetrieval();
      _firebaseMessaging.onTokenRefresh.listen((newToken) async {
        await _saveToken(newToken);
      });

      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings();

      await _notifications.initialize(
        InitializationSettings(iOS: initializationSettingsIOS),
        onDidReceiveNotificationResponse:
            (NotificationResponse response) async {
          if (response.payload != null) {
            try {
              jsonDecode(response.payload!);
            } catch (e) {}
          }
        },
      );

      await _configureNotificationChannels();
      _setupAuthListener();
    } catch (e) {}
  }

  Future<void> _setupAuthListener() async {
    firebase_auth.FirebaseAuth.instance.authStateChanges().listen((firebase_auth.User? user) async {
      if (user != null) {
        final token = await _firebaseMessaging.getToken();
        if (token != null) {
          await _saveToken(token);
        }
      }
    });
  }

  Future<void> _handleTokenRetrieval() async {
    try {
      final token = await _firebaseMessaging.getToken();
      if (token != null) {
        await _saveToken(token);
      }
    } catch (e) {}
  }

  Future<void> _configureNotificationChannels() async {
    try {
      final iOSPlugin = _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (iOSPlugin != null) {
        await iOSPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
    } catch (e) {}
  }

  // ─── UNIFIED TOKEN SAVER ────────────────────────────────────────────────
  // Saves to BOTH Supabase (primary) and Firestore (fallback).
  // This ensures the Cloud Function can always find the token regardless
  // of whether the user authenticated via Firebase or Supabase.
  Future<void> _saveToken(String token) async {
    await Future.wait([
      _saveTokenToSupabase(token),
      _saveTokenToFirestore(token),
    ]);
  }

  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final supabase = Supabase.instance.client;

      // Try Supabase auth session first
      final supabaseUser = supabase.auth.currentUser;
      if (supabaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token})
            .eq('supabase_uid', supabaseUser.id);
        print('[NotificationService] FCM token saved to Supabase via supabase_uid');
        return;
      }

      // Fall back to Firebase UID
      final firebaseUser = firebase_auth.FirebaseAuth.instance.currentUser;
      if (firebaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token})
            .eq('uid', firebaseUser.uid);
        print('[NotificationService] FCM token saved to Supabase via firebase uid');
        return;
      }

      print('[NotificationService] No auth session — storing token as pending');
      await _storePendingToken(token);
    } catch (e) {
      print('[NotificationService] Supabase token save error: $e');
    }
  }

  Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = firebase_auth.FirebaseAuth.instance.currentUser;
      if (user == null) return; // Firestore only for Firebase users

      await user.reload();
      if (!user.emailVerified) return;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
      print('[NotificationService] FCM token saved to Firestore');
    } catch (e) {
      print('[NotificationService] Firestore token save error: $e');
    }
  }

  Future<void> _storePendingToken(String token) async {
    try {
      await FirebaseFirestore.instance
          .collection('pending_tokens')
          .doc(token)
          .set({
        'token': token,
        'createdAt': FieldValue.serverTimestamp(),
        'associated': false,
      }, SetOptions(merge: true));
    } catch (e) {}
  }

  Future<void> _handleForegroundMessage(firebase_messaging.RemoteMessage message) async {
    // Foreground notifications disabled
  }

  static Future<void> _handleBackgroundMessage(firebase_messaging.RemoteMessage message) async {
    try {
      await Firebase.initializeApp();
      final title = message.data['title'] ?? message.notification?.title ?? '';
      final body = message.data['body'] ?? message.notification?.body ?? '';

      if (title.isNotEmpty || body.isNotEmpty) {
        final NotificationService service = NotificationService();
        await service._showNotification(
          title: title,
          body: body,
          data: message.data,
        );
      }
    } catch (e) {}
  }

  Future<void> _showNotification({
    required String? title,
    required String? body,
    required Map<String, dynamic> data,
  }) async {
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      categoryIdentifier: 'ratedly_actions',
      threadIdentifier: 'ratedly_notifications',
    );

    final notificationId = _getNotificationId();
    final finalTitle = title ?? data['title'] ?? 'New Activity';
    final finalBody = body ?? data['body'] ?? 'You have new activity';

    await _notifications.show(
      notificationId,
      finalTitle,
      finalBody,
      const NotificationDetails(iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  Future<void> triggerServerNotification({
    required String type,
    required String targetUserId,
    String? title,
    String? body,
    Map<String, dynamic>? customData,
  }) async {
    try {
      final notificationData = {
        'type': type,
        'targetUserId': targetUserId,
        'title': title ?? 'New Notification',
        'body': body ?? 'You have a new notification',
        'customData': customData ?? {},
        'createdAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('Push Not')
          .add(notificationData);
    } catch (e) {}
  }
}

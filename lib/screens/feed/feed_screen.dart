import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/global_variable.dart';
import 'package:Ratedly/screens/feed/post_card.dart' hide unawaited;
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/widgets/feedmessages.dart';
import 'package:Ratedly/services/ads.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/services/feed_cache_service.dart' hide unawaited;
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/feed/feed_skeleton.dart';

class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color skeletonColor;
  final Color progressIndicatorColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.skeletonColor,
    required this.progressIndicatorColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          skeletonColor: const Color(0xFF333333).withOpacity(0.6),
          progressIndicatorColor: Colors.white70,
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
          skeletonColor: Colors.grey[300]!.withOpacity(0.6),
          progressIndicatorColor: Colors.grey[700]!,
        );
}

// =============================================================================
// ERROR LOGGING HELPER
// =============================================================================
Future<void> _logFeedError({
  required String operation,
  required dynamic error,
  StackTrace? stack,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': 'FEED_ERROR',
      'firebase_uid': FirebaseAuth.instance.currentUser?.uid,
      'supabase_uid': Supabase.instance.client.auth.currentSession?.user.id,
      'error_details': error.toString(),
      'stack_trace': stack?.toString(),
      'additional_data': {
        'operation': operation,
        if (additionalData != null) ...additionalData,
      },
    });
  } catch (_) {}
}

class FeedScreen extends StatefulWidget {
  const FeedScreen({Key? key}) : super(key: key);

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  final SupabaseClient _supabase = Supabase.instance.client;
  String? currentUserId;

  int _selectedTab = 1;

  late PageController _followingPageController;
  late PageController _forYouPageController;

  List<Map<String, dynamic>> _followingPosts = [];
  List<Map<String, dynamic>> _forYouPosts = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  int _offsetFollowing = 0;
  int _offsetForYou = 0;
  bool _hasMoreFollowing = true;
  bool _hasMoreForYou = true;

  List<String> _blockedUsers = [];
  List<String> _followingIds = [];
  bool _viewRecordingScheduled = false;
  final Set<String> _pendingViews = {};

  int _currentForYouPage = 0;
  int _currentFollowingPage = 0;
  final Map<String, bool> _postVisibility = {};
  String? _currentPlayingPostId;

  final Map<String, Map<String, dynamic>> _postCache = {};
  static const int _preloadCount = 2;

  InterstitialAd? _interstitialAd;
  int _postViewCount = 0;
  DateTime? _lastInterstitialAdTime;

  Stream<int>? _unreadCountStream;
  StreamController<int>? _unreadCountController;
  Timer? _unreadCountTimer;

  final Map<String, Map<String, dynamic>> _userCache = {};
  static final Map<String, List<String>> _blockedUsersCache = {};
  static DateTime? _lastBlockedUsersCacheTime;

  List<Map<String, dynamic>> _nextForYouBatch = [];
  bool _nextBatchLoaded = false;

  static const int _mediaPreloadAhead = 4;
  static const int _mediaPreloadBehind = 2;
  final Map<String, VideoPlayerController> _feedVideoControllers = {};
  final Map<String, bool> _feedVideoControllersInitialized = {};
  final Map<String, Future<void>> _videoInitializationFutures = {};
  final Map<String, bool> _imagePreloaded = {};
  final Map<String, FileInfo?> _cachedImageInfo = {};
  final Map<String, ImageProvider> _loadedImageProviders = {};
  final List<Map<String, dynamic>> _visiblePosts = [];
  int _currentVisibleIndex = 0;
  static const int _visiblePostsCount = 3;

  // ⚡ Use the same batch size as the original A (10) for the RPC call.
  static const int _initialBatchSize = 10;

  bool _essentialUiReady = false;
  bool _showOverlay = true;
  double _lastScrollOffset = 0;
  bool _firstVideoInitialized = false;
  final Map<String, bool> _postReadyToShow = {};
  final Set<String> _postsBeingPreloaded = {};
  final Set<String> _postsFullyPreloaded = {};

  bool _cacheLoadAttempted = false;
  bool _cacheLoaded = false;
  Timer? _delayedCacheUpdateTimer;

  bool _followingIdsLoaded = false;

  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
  }

  dynamic _unwrapResponse(dynamic res) {
    if (res == null) return null;
    if (res is Map && res.containsKey('data')) return res['data'];
    return res;
  }

  void _pauseCurrentVideo() {
    VideoManager.pauseAllVideos();
    if (mounted) {
      setState(() {
        _currentPlayingPostId = null;
      });
    } else {
      _currentPlayingPostId = null;
    }
  }

  void _cachePost(Map<String, dynamic> post) {
    final postId = post['postId']?.toString();
    if (postId != null && postId.isNotEmpty) {
      _postCache[postId] = Map<String, dynamic>.from(post);
    }
  }

  Map<String, dynamic>? _getCachedPost(String postId) {
    return _postCache[postId];
  }

  bool _isVideoFile(String url) {
    if (url.isEmpty) return false;
    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.endsWith('.avi') ||
        lowerUrl.endsWith('.wmv') ||
        lowerUrl.endsWith('.flv') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.webm') ||
        lowerUrl.endsWith('.m4v') ||
        lowerUrl.endsWith('.3gp') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.contains('video=true');
  }

  bool _isImageFile(String url) {
    if (url.isEmpty) return false;
    final lowerUrl = url.toLowerCase();

    final hasImageExtension = lowerUrl.endsWith('.jpg') ||
        lowerUrl.endsWith('.jpeg') ||
        lowerUrl.endsWith('.png') ||
        lowerUrl.endsWith('.gif') ||
        lowerUrl.endsWith('.webp') ||
        lowerUrl.endsWith('.bmp') ||
        lowerUrl.endsWith('.svg');

    final hasImagePath = lowerUrl.contains('/image/') ||
        lowerUrl.contains('/images/') ||
        lowerUrl.contains('/img/') ||
        lowerUrl.contains('image=true') ||
        lowerUrl.contains('type=image');

    final isSupabaseImage =
        lowerUrl.contains('supabase.co/storage/v1/object/public/') &&
            (lowerUrl.contains('/images/') ||
                lowerUrl.contains('/Images/') ||
                lowerUrl.contains('/posts/') ||
                (lowerUrl.contains('/videos/') && hasImageExtension));

    final isFirebaseImage =
        lowerUrl.contains('firebasestorage.googleapis.com') &&
            (lowerUrl.contains('_1024x1024') ||
                lowerUrl.contains('alt=media') ||
                lowerUrl.contains('/posts/') ||
                lowerUrl.contains('/images/') ||
                lowerUrl.contains('/profilepics/') ||
                lowerUrl.contains('/profilePics/'));

    final hasThumbnailPattern = lowerUrl.contains('thumb') ||
        lowerUrl.contains('thumbnail') ||
        lowerUrl.contains('_thumb') ||
        lowerUrl.contains('_thumbnail');

    final hasImageQueryParam = lowerUrl.contains('format=jpg') ||
        lowerUrl.contains('format=png') ||
        lowerUrl.contains('format=webp') ||
        lowerUrl.contains('image/jpeg') ||
        lowerUrl.contains('image/png');

    return hasImageExtension ||
        hasImagePath ||
        isSupabaseImage ||
        isFirebaseImage ||
        hasThumbnailPattern ||
        hasImageQueryParam;
  }

  bool _isFirebaseStorageUrl(String url) {
    return url.contains('firebasestorage.googleapis.com') &&
        url.contains('alt=media') &&
        (url.contains('/profilePics/') ||
            url.contains('/posts/') ||
            url.contains('/images/'));
  }

  List<String> _getAllImageUrlsFromPost(Map<String, dynamic> post) {
    final urls = <String>{};
    final postUrl = post['postUrl']?.toString() ?? '';
    final thumbnailUrl = post['thumbnailUrl']?.toString() ?? '';
    final imageUrl = post['imageUrl']?.toString() ?? '';
    final profImageUrl = post['profImage']?.toString() ?? '';

    final List<String> allUrls = [
      postUrl,
      thumbnailUrl,
      imageUrl,
      profImageUrl
    ];

    for (final url in allUrls) {
      if (url.isNotEmpty && _isImageFile(url)) {
        urls.add(url);
      }
    }

    for (final key in post.keys) {
      final value = post[key]?.toString() ?? '';
      if (value.isNotEmpty &&
          value.contains('http') &&
          _isImageFile(value) &&
          !urls.contains(value)) {
        urls.add(value);
      }
    }

    return urls.toList();
  }

  Future<void> _preloadAllMediaForPost(Map<String, dynamic> post) async {
    final startTime = DateTime.now().millisecondsSinceEpoch;
    final postId = post['postId']?.toString() ?? '';
    final postUrl = post['postUrl']?.toString() ?? '';

    if (postId.isEmpty) return;

    if (_postsBeingPreloaded.contains(postId) ||
        _postsFullyPreloaded.contains(postId)) {
      return;
    }

    _postsBeingPreloaded.add(postId);

    final completer = Completer<void>();
    int mediaToPreload = 0;
    int mediaPreloaded = 0;

    void checkCompletion() {
      mediaPreloaded++;

      if (mediaPreloaded >= mediaToPreload && !completer.isCompleted) {
        _postsBeingPreloaded.remove(postId);
        _postsFullyPreloaded.add(postId);

        if (mounted) {
          setState(() {
            _postReadyToShow[postId] = true;
          });
        }

        completer.complete();
      }
    }

    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      mediaToPreload++;

      try {
        if (_feedVideoControllers.containsKey(postUrl) &&
            _feedVideoControllersInitialized[postUrl] == true) {
          checkCompletion();
        } else {
          await _initializeFeedVideoController(postUrl, postId);
          checkCompletion();
        }
      } catch (e, stack) {
        await _logFeedError(
          operation: '_preloadAllMediaForPost/video',
          error: e,
          stack: stack,
          additionalData: {'postId': postId, 'postUrl': postUrl},
        );
        checkCompletion();
      }
    }

    final imageUrls = _getAllImageUrlsFromPost(post);
    if (imageUrls.isNotEmpty) {
      for (final imageUrl in imageUrls) {
        if (imageUrl.isNotEmpty && !_imagePreloaded.containsKey(imageUrl)) {
          mediaToPreload++;

          _preloadImage(imageUrl, postId).then((_) {
            checkCompletion();
          }).catchError((e, stack) async {
            await _logFeedError(
              operation: '_preloadAllMediaForPost/image',
              error: e,
              stack: stack,
              additionalData: {'postId': postId, 'imageUrl': imageUrl},
            );
            checkCompletion();
          });
        }
      }
    }

    if (!_isVideoFile(postUrl) && imageUrls.isEmpty) {
      _postsBeingPreloaded.remove(postId);
      _postsFullyPreloaded.add(postId);

      if (mounted) {
        setState(() {
          _postReadyToShow[postId] = true;
        });
      }

      completer.complete();
    }

    if (mediaToPreload == 0) {
      _checkAndMarkPostReady(postId);
    }

    return completer.future;
  }

  void _preloadAllMediaForPosts(List<Map<String, dynamic>> posts) {
    if (posts.isEmpty) return;

    final postsToPreload = posts.where((post) {
      final postId = post['postId']?.toString() ?? '';
      return postId.isNotEmpty &&
          !_postsBeingPreloaded.contains(postId) &&
          !_postsFullyPreloaded.contains(postId);
    }).toList();

    if (postsToPreload.isEmpty) return;

    for (final post in postsToPreload) {
      final postId = post['postId']?.toString() ?? '';
      if (postId.isNotEmpty) {
        unawaited(_preloadAllMediaForPost(post));
      }
    }
  }

  Future<void> _preloadImage(String imageUrl, String postId) async {
    if (imageUrl.isEmpty) return;

    if (_imagePreloaded[imageUrl] == true) return;

    try {
      _imagePreloaded[imageUrl] = false;

      if (_isFirebaseStorageUrl(imageUrl)) {
        await _preloadFirebaseImageWithSDK(imageUrl, postId);
      } else {
        await _preloadRegularImage(imageUrl, postId);
      }

      _checkAndMarkPostReady(postId);
    } catch (e, stack) {
      await _logFeedError(
        operation: '_preloadImage',
        error: e,
        stack: stack,
        additionalData: {'imageUrl': imageUrl, 'postId': postId},
      );
      _imagePreloaded[imageUrl] = false;
      _checkAndMarkPostReady(postId);
    }
  }

  Future<void> _preloadFirebaseImageWithSDK(
      String imageUrl, String postId) async {
    try {
      final ref = FirebaseStorage.instance.refFromURL(imageUrl);
      const maxSize = 2 * 1024 * 1024;
      final Uint8List? imageBytes = await ref.getData(maxSize);

      if (imageBytes != null && imageBytes.isNotEmpty) {
        final imageProvider = MemoryImage(imageBytes);
        await _loadImageIntoMemory(imageProvider);
        _loadedImageProviders[imageUrl] = imageProvider;
        _imagePreloaded[imageUrl] = true;
      } else {
        throw Exception('Firebase SDK returned null or empty bytes');
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_preloadFirebaseImageWithSDK',
        error: e,
        stack: stack,
        additionalData: {'imageUrl': imageUrl, 'postId': postId},
      );
      try {
        await _preloadFirebaseImageAlternative(imageUrl, postId);
      } catch (fallbackError, fallbackStack) {
        await _logFeedError(
          operation: '_preloadFirebaseImageAlternative',
          error: fallbackError,
          stack: fallbackStack,
          additionalData: {'imageUrl': imageUrl, 'postId': postId},
        );
        rethrow;
      }
    }
  }

  Future<void> _preloadFirebaseImageAlternative(
      String imageUrl, String postId) async {
    try {
      final uri = Uri.parse(imageUrl);
      final path = uri.path;
      final parts = path.split('/o/');
      if (parts.length >= 2) {
        final encodedPath = parts[1];
        final storagePath = Uri.decodeFull(encodedPath);
        final ref = FirebaseStorage.instance.ref().child(storagePath);
        const maxSize = 2 * 1024 * 1024;
        final Uint8List? imageBytes = await ref.getData(maxSize);

        if (imageBytes != null && imageBytes.isNotEmpty) {
          final imageProvider = MemoryImage(imageBytes);
          await _loadImageIntoMemory(imageProvider);
          _loadedImageProviders[imageUrl] = imageProvider;
          _imagePreloaded[imageUrl] = true;
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _preloadRegularImage(String imageUrl, String postId) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(
        imageUrl,
        headers: {
          'Cache-Control': 'max-age=604800',
          'Pragma': 'cache',
        },
      );

      if (file.existsSync()) {
        _cachedImageInfo[imageUrl] = FileInfo(
          file,
          FileSource.Online,
          DateTime.now().add(const Duration(days: 7)),
          imageUrl,
        );

        final imageProvider = FileImage(file);
        await _loadImageIntoMemory(imageProvider);
        _loadedImageProviders[imageUrl] = imageProvider;
        _imagePreloaded[imageUrl] = true;
      } else {
        throw Exception('Image file does not exist: $imageUrl');
      }
    } catch (e) {
      rethrow;
    }
  }

  void _checkAndMarkPostReady(String postId) {
    final post = _forYouPosts.firstWhere(
      (p) => p['postId']?.toString() == postId,
      orElse: () => _followingPosts.firstWhere(
        (p) => p['postId']?.toString() == postId,
        orElse: () => {},
      ),
    );

    if (post.isEmpty) return;

    final postUrl = post['postUrl']?.toString() ?? '';
    final imageUrls = _getAllImageUrlsFromPost(post);

    bool allMediaReady = true;

    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      if (!_feedVideoControllersInitialized.containsKey(postUrl) ||
          _feedVideoControllersInitialized[postUrl] != true) {
        allMediaReady = false;
      }
    }

    for (final imageUrl in imageUrls) {
      if (!_imagePreloaded.containsKey(imageUrl) ||
          _imagePreloaded[imageUrl] != true) {
        allMediaReady = false;
        break;
      }
    }

    if (allMediaReady) {
      _postsBeingPreloaded.remove(postId);
      _postsFullyPreloaded.add(postId);

      if (mounted) {
        setState(() {
          _postReadyToShow[postId] = true;
        });
      }
    }
  }

  Future<void> _loadImageIntoMemory(ImageProvider imageProvider) async {
    try {
      final configuration = ImageConfiguration.empty;
      final stream = imageProvider.resolve(configuration);

      final completer = Completer<void>();
      final listener = ImageStreamListener(
        (ImageInfo info, bool synchronousCall) {
          completer.complete();
        },
        onError: (exception, stackTrace) {
          completer.complete();
        },
      );

      stream.addListener(listener);
      await completer.future.timeout(Duration(seconds: 5));
      stream.removeListener(listener);
    } catch (e) {}
  }

  ImageProvider? _getPreloadedImageProvider(String imageUrl) {
    return _loadedImageProviders[imageUrl];
  }

  Future<void> _initializeFeedVideoController(
      String videoUrl, String postId) async {
    if (_videoInitializationFutures.containsKey(videoUrl)) {
      await _videoInitializationFutures[videoUrl];
      return;
    }

    if (_feedVideoControllers.containsKey(videoUrl) &&
        _feedVideoControllersInitialized[videoUrl] == true) {
      return;
    }

    final completer = Completer<void>();
    _videoInitializationFutures[videoUrl] = completer.future;

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      _feedVideoControllers[videoUrl] = controller;
      _feedVideoControllersInitialized[videoUrl] = false;

      await controller.initialize().timeout(
        Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('Video initialization timeout');
        },
      );

      await controller.setVolume(0.0);
      _feedVideoControllersInitialized[videoUrl] = true;
      _checkAndMarkPostReady(postId);
      completer.complete();
    } catch (e, stack) {
      await _logFeedError(
        operation: '_initializeFeedVideoController',
        error: e,
        stack: stack,
        additionalData: {'videoUrl': videoUrl, 'postId': postId},
      );
      try {
        final controller = _feedVideoControllers.remove(videoUrl);
        if (controller != null) controller.dispose();
      } catch (disposeError) {}

      _feedVideoControllersInitialized.remove(videoUrl);
      _videoInitializationFutures.remove(videoUrl);
      completer.completeError(e);
    } finally {
      _videoInitializationFutures.remove(videoUrl);
    }
  }

  VideoPlayerController? _getPreloadedVideoController(String videoUrl) {
    return _feedVideoControllers[videoUrl];
  }

  bool _isVideoControllerInitialized(String videoUrl) {
    return _feedVideoControllersInitialized[videoUrl] == true;
  }

  void _updateVisiblePosts(int centerIndex) {
    final currentPosts = _selectedTab == 1 ? _forYouPosts : _followingPosts;

    if (currentPosts.isEmpty) return;

    int preloadStart = max(0, centerIndex - _mediaPreloadBehind);
    int preloadEnd =
        min(currentPosts.length - 1, centerIndex + _mediaPreloadAhead);

    final List<Map<String, dynamic>> postsToPreload = [];
    for (int i = preloadStart; i <= preloadEnd; i++) {
      if (i < currentPosts.length) {
        final post = currentPosts[i];
        final postId = post['postId']?.toString() ?? '';

        if (postId.isNotEmpty &&
            !_postsFullyPreloaded.contains(postId) &&
            !_postsBeingPreloaded.contains(postId)) {
          postsToPreload.add(post);
        }
      }
    }

    if (postsToPreload.isNotEmpty) {
      _preloadAllMediaForPosts(postsToPreload);
    }

    int visibleStart = max(0, centerIndex - 1);
    int visibleEnd = min(currentPosts.length - 1, centerIndex + 1);

    _visiblePosts.clear();
    for (int i = visibleStart; i <= visibleEnd; i++) {
      if (i < currentPosts.length) {
        _visiblePosts.add(currentPosts[i]);
      }
    }

    _cleanupUnusedMediaControllers(
        preloadStart - 3, preloadEnd + 3, currentPosts);

    if (mounted) {
      setState(() {
        _currentVisibleIndex = centerIndex;
      });
    }
  }

  void _cleanupUnusedMediaControllers(int preloadStart, int preloadEnd,
      List<Map<String, dynamic>> currentPosts) {
    final preloadedUrls = <String>{};

    for (int i = preloadStart; i <= preloadEnd; i++) {
      if (i >= 0 && i < currentPosts.length) {
        final post = currentPosts[i];
        final postUrl = post['postUrl']?.toString() ?? '';
        final imageUrls = _getAllImageUrlsFromPost(post);

        if (postUrl.isNotEmpty) preloadedUrls.add(postUrl);
        for (final imageUrl in imageUrls) {
          preloadedUrls.add(imageUrl);
        }
      }
    }

    final videoUrlsToRemove = <String>[];

    for (final url in _feedVideoControllers.keys) {
      bool isInAnyPost = false;
      for (final post in currentPosts) {
        final postUrl = post['postUrl']?.toString() ?? '';
        if (postUrl == url) {
          isInAnyPost = true;
          break;
        }
      }

      if (!isInAnyPost && !preloadedUrls.contains(url)) {
        videoUrlsToRemove.add(url);
      }
    }

    for (final url in videoUrlsToRemove) {
      final controller = _feedVideoControllers.remove(url);
      _feedVideoControllersInitialized.remove(url);
      _videoInitializationFutures.remove(url);

      if (controller != null && controller.value.isInitialized) {
        try {
          controller.pause();
          Future.delayed(Duration(milliseconds: 100), () {
            try {
              controller.dispose();
            } catch (e) {}
          });
        } catch (e) {}
      }
    }

    final List<String> keysToRemove = [];
    for (final key in _feedVideoControllers.keys) {
      final controller = _feedVideoControllers[key];
      if (controller == null || !controller.value.isInitialized) {
        keysToRemove.add(key);
      }
    }

    for (final key in keysToRemove) {
      _feedVideoControllers.remove(key);
      _feedVideoControllersInitialized.remove(key);
      _videoInitializationFutures.remove(key);
    }

    if (_loadedImageProviders.length > 100) {
      final imageUrlsToRemove = <String>{};
      for (final url in _loadedImageProviders.keys) {
        if (!preloadedUrls.contains(url)) {
          imageUrlsToRemove.add(url);
        }
      }

      for (final url in imageUrlsToRemove) {
        _loadedImageProviders.remove(url);
        _imagePreloaded.remove(url);
        _cachedImageInfo.remove(url);
      }
    }
  }

  Future<void> _scheduleViewRecording(String postId) async {
    _pendingViews.add(postId);
    if (!_viewRecordingScheduled) {
      _viewRecordingScheduled = true;
      await Future.delayed(const Duration(seconds: 1));
      await _recordPendingViews();
    }
  }

  Future<void> _recordPendingViews() async {
    if (_pendingViews.isEmpty || !mounted) {
      _viewRecordingScheduled = false;
      return;
    }

    final viewsToRecord = _pendingViews.toList();
    _pendingViews.clear();

    try {
      final userId = currentUserId ?? '';
      await _supabase.from('user_post_views').upsert(
            viewsToRecord
                .map((postId) => ({
                      'user_id': userId,
                      'post_id': postId,
                      'viewed_at': DateTime.now().toUtc().toIso8601String(),
                    }))
                .toList(),
          );

      setState(() {
        _postViewCount += viewsToRecord.length;
      });

      if (_postViewCount >= 10) {
        _showInterstitialAd();
        _postViewCount = 0;
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_recordPendingViews',
        error: e,
        stack: stack,
        additionalData: {'views': viewsToRecord.length},
      );
    } finally {
      _viewRecordingScheduled = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    FeedCacheService.resetSession();

    _followingPageController = PageController();
    _forYouPageController = PageController();

    _loadCachedPostsLightningFast();
    _loadInterstitialAd();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && currentUserId == null) {
      currentUserId = userProvider.firebaseUid;
      _unreadCountStream = _createUnreadCountStream();
      _loadInitialData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        currentUserId == null) {
      currentUserId = userProvider.supabaseUid;
      _unreadCountStream = _createUnreadCountStream();
      _loadInitialData();
    } else if (currentUserId == null) {
      _loadInitialData();
    }
  }

  Future<void> _loadCachedPostsLightningFast() async {
    if (_cacheLoadAttempted) return;

    _cacheLoadAttempted = true;

    if (currentUserId == null || currentUserId!.isEmpty) {
      currentUserId = FirebaseAuth.instance.currentUser?.uid;
    }
    if (currentUserId == null || currentUserId!.isEmpty) {
      _essentialUiReady = true;
      if (mounted) setState(() {});
      return;
    }

    try {
      final cachedPosts =
          await FeedCacheService.loadCachedForYouPosts(currentUserId!);

      if (cachedPosts != null && cachedPosts.isNotEmpty) {
        _cacheLoaded = true;

        if (mounted) {
          setState(() {
            _forYouPosts = cachedPosts;
            _essentialUiReady = true;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _postsBeingPreloaded.clear();
              _postsFullyPreloaded.clear();

              // Preload only first 3 posts for faster initial paint
              final toPreload = cachedPosts.length > 3
                  ? cachedPosts.sublist(0, 3)
                  : cachedPosts;
              _preloadAllMediaForPosts(toPreload);

              if (_forYouPosts.isNotEmpty) {
                final firstPost = _forYouPosts.first;
                final firstPostId = firstPost['postId']?.toString() ?? '';
                if (firstPostId.isNotEmpty) {
                  _postVisibility[firstPostId] = true;
                  _currentPlayingPostId = firstPostId;
                  _firstVideoInitialized = false;
                  _updateVisiblePosts(0);
                }
              }
            }
          });
        }
      } else {
        _essentialUiReady = true;
        if (mounted) setState(() {});
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadCachedPostsLightningFast',
        error: e,
        stack: stack,
        additionalData: {'userId': currentUserId},
      );
      _essentialUiReady = true;
      if (mounted) setState(() {});
    }
  }

  Stream<int> _createUnreadCountStream() {
    _unreadCountController = StreamController<int>.broadcast();

    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _unreadCountController!.add(0);
      return _unreadCountController!.stream;
    }

    _unreadCountTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final data = await _supabase
            .from('messages')
            .select('id')
            .eq('receiver_id', userId)
            .eq('is_read', false);

        final int count = (data is List) ? data.length : 0;
        if (_unreadCountController != null &&
            !_unreadCountController!.isClosed) {
          _unreadCountController!.add(count);
        }
      } catch (e, stack) {
        await _logFeedError(
          operation: '_unreadCountTimer',
          error: e,
          stack: stack,
          additionalData: {'userId': userId},
        );
        if (_unreadCountController != null &&
            !_unreadCountController!.isClosed) {
          _unreadCountController!.add(0);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final data = await _supabase
            .from('messages')
            .select('id')
            .eq('receiver_id', userId)
            .eq('is_read', false);

        final int count = (data is List) ? data.length : 0;
        if (_unreadCountController != null &&
            !_unreadCountController!.isClosed) {
          _unreadCountController!.add(count);
        }
      } catch (e, stack) {
        await _logFeedError(
          operation: '_createUnreadCountStream_initial',
          error: e,
          stack: stack,
          additionalData: {'userId': userId},
        );
        if (_unreadCountController != null &&
            !_unreadCountController!.isClosed) {
          _unreadCountController!.add(0);
        }
      }
    });

    return _unreadCountController!.stream;
  }

  Future<void> _bulkFetchUsers(List<Map<String, dynamic>> posts) async {
    final Set<String> userIds = {};

    for (final post in posts) {
      final userId = post['uid']?.toString() ?? '';
      if (userId.isNotEmpty && !_userCache.containsKey(userId)) {
        userIds.add(userId);
      }
    }

    if (userIds.isEmpty) return;

    try {
      final response = await _supabase
          .from('users')
          .select('uid, username, photoUrl')
          .inFilter('uid', userIds.toList());

      if (response.isNotEmpty) {
        for (final user in response) {
          final userMap = Map<String, dynamic>.from(user);
          _userCache[userMap['uid']] = userMap;
        }
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_bulkFetchUsers',
        error: e,
        stack: stack,
        additionalData: {'userCount': userIds.length},
      );
    }
  }

  void _updatePostVisibility(
      int page, List<Map<String, dynamic>> posts, bool isForYou) {
    if (!mounted || posts.isEmpty) return;

    final previouslyPlayingPostId = _currentPlayingPostId;
    String? newPlayingPostId;

    setState(() {
      for (final post in posts) {
        final postId = post['postId']?.toString() ?? '';
        if (postId.isNotEmpty) {
          _postVisibility[postId] = false;
        }
      }

      if (page < posts.length) {
        final currentPost = posts[page];
        final postId = currentPost['postId']?.toString() ?? '';
        if (postId.isNotEmpty) {
          _postVisibility[postId] = true;
          newPlayingPostId = postId;
          unawaited(_scheduleViewRecording(postId));

          if (page == 0 && isForYou && !_firstVideoInitialized) {
            _firstVideoInitialized = true;
          }
        }
      }

      if (page > 0) {
        final previousPost = posts[page - 1];
        final previousPostId = previousPost['postId']?.toString() ?? '';
        if (previousPostId.isNotEmpty) {
          _postVisibility[previousPostId] = true;
        }
      }

      if (page < posts.length - 1) {
        final nextPost = posts[page + 1];
        final nextPostId = nextPost['postId']?.toString() ?? '';
        if (nextPostId.isNotEmpty) {
          _postVisibility[nextPostId] = true;
        }
      }

      _updateVisiblePosts(page);
    });

    if (newPlayingPostId != null &&
        newPlayingPostId != previouslyPlayingPostId) {
      _currentPlayingPostId = newPlayingPostId;

      if (previouslyPlayingPostId != null) {
        VideoManager.pauseAllVideos();
      }
    }

    if (isForYou) {
      unawaited(_delayedCacheUpdate());
    }
  }

  Future<void> _delayedCacheUpdate() async {
    _delayedCacheUpdateTimer?.cancel();

    _delayedCacheUpdateTimer = Timer(Duration(seconds: 2), () async {
      if (!mounted) return;

      if (_nextForYouBatch.isEmpty && !_nextBatchLoaded) {
        _nextForYouBatch = await _loadNextForYouBatch();
        _nextBatchLoaded = true;
      }

      final userId = currentUserId;
      if (_nextForYouBatch.isNotEmpty && userId != null) {
        await FeedCacheService.safeCacheUpdate(
            userId, _forYouPosts, _nextForYouBatch);
      }
    });
  }

  void _onPageChanged(int page, bool isForYou) {
    if (isForYou) {
      _currentForYouPage = page;
      _updatePostVisibility(page, _forYouPosts, true);
    } else {
      _currentFollowingPage = page;
      _updatePostVisibility(page, _followingPosts, false);
    }

    final currentPosts = isForYou ? _forYouPosts : _followingPosts;

    final postsToPreload = <Map<String, dynamic>>[];
    for (int i = 1; i <= 3; i++) {
      final nextPage = page + i;
      if (nextPage < currentPosts.length) {
        final nextPost = currentPosts[nextPage];
        final nextPostId = nextPost['postId']?.toString() ?? '';
        if (nextPostId.isNotEmpty &&
            !_postsFullyPreloaded.contains(nextPostId) &&
            !_postsBeingPreloaded.contains(nextPostId)) {
          postsToPreload.add(nextPost);
        }
      }
    }

    if (postsToPreload.isNotEmpty) {
      _preloadAllMediaForPosts(postsToPreload);
    }

    final hasMore = isForYou ? _hasMoreForYou : _hasMoreFollowing;
    if (page >= currentPosts.length - 3 && hasMore && !_isLoadingMore) {
      _loadData(loadMore: true);
    }
  }

  void _openComments(BuildContext context, Map<String, dynamic> post) {
    final postId = post['postId']?.toString() ?? '';
    final isVideo = _isVideoFile(post['postUrl']?.toString() ?? '');
    final postImage = post['postUrl']?.toString() ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => CommentsBottomSheet(
        postId: postId,
        postImage: postImage,
        isVideo: isVideo,
        onClose: () {},
      ),
    );
  }

  void _loadInterstitialAd() {
    InterstitialAd.load(
      adUnitId: AdHelper.feedInterstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _interstitialAd = ad;
          _interstitialAd!.fullScreenContentCallback =
              FullScreenContentCallback(
            onAdDismissedFullScreenContent: (InterstitialAd ad) {
              ad.dispose();
              _loadInterstitialAd();
            },
            onAdFailedToShowFullScreenContent:
                (InterstitialAd ad, AdError error) {
              ad.dispose();
              _loadInterstitialAd();
            },
          );
        },
        onAdFailedToLoad: (LoadAdError error) {
          Future.delayed(const Duration(seconds: 30), () {
            _loadInterstitialAd();
          });
        },
      ),
    );
  }

  void _showInterstitialAd() {
    final now = DateTime.now();
    if (_lastInterstitialAdTime != null &&
        now.difference(_lastInterstitialAdTime!) <
            const Duration(minutes: 10)) {
      return;
    }

    if (_interstitialAd != null) {
      _interstitialAd!.show();
      _lastInterstitialAdTime = now;
    } else {
      _loadInterstitialAd();
    }
  }

  Future<void> _loadBlockedUsers() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _blockedUsers = [];
      return;
    }

    final now = DateTime.now();
    if (_blockedUsersCache[userId] != null &&
        _lastBlockedUsersCacheTime != null &&
        now.difference(_lastBlockedUsersCacheTime!) < Duration(minutes: 5)) {
      _blockedUsers = _blockedUsersCache[userId]!;
      return;
    }

    try {
      final userResponseRaw = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', userId)
          .maybeSingle();

      final userResponse = _unwrapResponse(userResponseRaw);
      if (userResponse != null && userResponse is Map) {
        final blocked = userResponse['blockedUsers'];
        if (blocked is List) {
          _blockedUsers = blocked.map((e) => e.toString()).toList();
        } else if (blocked is String) {
          try {
            final parsed = jsonDecode(blocked) as List;
            _blockedUsers = parsed.map((e) => e.toString()).toList();
          } catch (e, stack) {
            await _logFeedError(
              operation: '_loadBlockedUsers_json',
              error: e,
              stack: stack,
              additionalData: {'userId': userId},
            );
            _blockedUsers = [];
          }
        } else {
          _blockedUsers = [];
        }
      } else {
        _blockedUsers = [];
      }

      _blockedUsersCache[userId] = _blockedUsers;
      _lastBlockedUsersCacheTime = now;
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadBlockedUsers',
        error: e,
        stack: stack,
        additionalData: {'userId': userId},
      );
      _blockedUsers = [];
    }
  }

  Future<void> _loadFollowingIds() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _followingIds = [];
      return;
    }

    try {
      final followingResponseRaw = await _supabase
          .from('user_following')
          .select('following_id')
          .eq('user_id', userId);

      final followingResponse = _unwrapResponse(followingResponseRaw);
      if (followingResponse is List) {
        _followingIds = followingResponse
            .map((row) => row['following_id'].toString())
            .toList();
      } else {
        _followingIds = [];
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadFollowingIds',
        error: e,
        stack: stack,
        additionalData: {'userId': userId},
      );
      _followingIds = [];
    }
  }

  Future<void> _loadInitialData() async {
    if (!mounted) return;

    try {
      if (currentUserId == null || currentUserId!.isEmpty) {
        final userProvider = Provider.of<UserProvider>(context, listen: false);
        currentUserId =
            userProvider.firebaseUid ?? userProvider.supabaseUid ?? '';
      }

      if (!_cacheLoadAttempted) {
        final cachedPosts =
            await FeedCacheService.loadCachedForYouPosts(currentUserId ?? '');

        if (cachedPosts != null && cachedPosts.isNotEmpty) {
          _cacheLoaded = true;

          setState(() {
            _forYouPosts = cachedPosts;
            _isLoading = false;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _postsBeingPreloaded.clear();
              _postsFullyPreloaded.clear();

              final toPreload = cachedPosts.length > 3
                  ? cachedPosts.sublist(0, 3)
                  : cachedPosts;
              _preloadAllMediaForPosts(toPreload);
            }
          });

          if (_forYouPosts.isNotEmpty) {
            final firstPost = _forYouPosts.first;
            final firstPostId = firstPost['postId']?.toString() ?? '';
            if (firstPostId.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _postVisibility[firstPostId] = true;
                    _currentPlayingPostId = firstPostId;
                    _firstVideoInitialized = false;
                  });
                  unawaited(_scheduleViewRecording(firstPostId));
                  _updateVisiblePosts(0);
                }
              });
            }
          }

          unawaited(() async {
            _nextForYouBatch = await _loadNextForYouBatch();
            _nextBatchLoaded = true;
          }());

          return;
        }
      }

      if (_essentialUiReady && _forYouPosts.isNotEmpty) {
        unawaited(() async {
          _nextForYouBatch = await _loadNextForYouBatch();
          _nextBatchLoaded = true;
        }());

        if (currentUserId == null || currentUserId!.isEmpty) {
          _blockedUsers = [];
        } else {
          await _loadBlockedUsers();
        }

        await _loadData();

        if (mounted) {
          setState(() => _isLoading = false);

          if (_forYouPosts.isNotEmpty && _selectedTab == 1) {
            final firstPost = _forYouPosts.first;
            final firstPostId = firstPost['postId']?.toString() ?? '';
            if (firstPostId.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _postVisibility[firstPostId] = true;
                    _currentPlayingPostId = firstPostId;
                    _firstVideoInitialized = true;
                  });
                  unawaited(_scheduleViewRecording(firstPostId));
                  _updateVisiblePosts(0);
                }
              });
            }
          }
        }
        return;
      }

      if (currentUserId == null || currentUserId!.isEmpty) {
        _blockedUsers = [];
      } else {
        await _loadBlockedUsers();
      }

      await _loadData();
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadInitialData',
        error: e,
        stack: stack,
        additionalData: {'userId': currentUserId},
      );
      if (mounted) setState(() => _isLoading = false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _essentialUiReady = true;
        });
      }
    }
  }

  Future<List<Map<String, dynamic>>> _loadNextForYouBatch() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) return [];

    try {
      final excludedUsers = [..._blockedUsers, userId];

      final responseRaw = await _supabase.rpc('get_for_you_feed', params: {
        'current_user_id': userId,
        'excluded_users': excludedUsers,
        'page_offset': _offsetForYou + _initialBatchSize,
        'page_limit': _initialBatchSize,
      });

      final response = _unwrapResponse(responseRaw);
      if (response is List) {
        final result = response.map<Map<String, dynamic>>((post) {
          final Map<String, dynamic> convertedPost = {};
          (post as Map).forEach((key, value) {
            if (key.toString() == 'postScore') {
              convertedPost['score'] = value;
            } else {
              convertedPost[key.toString()] = value;
            }
          });
          convertedPost['postId'] = convertedPost['postId']?.toString();
          return convertedPost;
        }).toList();
        return result;
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadNextForYouBatch',
        error: e,
        stack: stack,
        additionalData: {'userId': userId},
      );
    }
    return [];
  }

  void _onPostSeen(String postId) {
    final userId = currentUserId;
    if (userId != null && userId.isNotEmpty) {
      FeedCacheService.markPostAsSeen(postId, userId);
    }
  }

  Future<void> _loadData({bool loadMore = false}) async {
    if ((_selectedTab == 1 && !_hasMoreForYou && loadMore) ||
        (_selectedTab == 0 && !_hasMoreFollowing && loadMore) ||
        _isLoadingMore) {
      return;
    }

    if (mounted) setState(() => _isLoadingMore = true);

    try {
      List<Map<String, dynamic>> newPosts = [];
      final userId = currentUserId ?? '';
      final excludedUsers = [..._blockedUsers, userId];

      if (_selectedTab == 0) {
        if (_followingIds.isEmpty) {
          setState(() {
            _hasMoreFollowing = false;
            _isLoadingMore = false;
          });
          return;
        }

        final responseRaw = await _supabase.rpc('get_following_feed', params: {
          'current_user_id': userId,
          'excluded_users': excludedUsers,
          'following_ids': _followingIds,
          'page_offset': _offsetFollowing,
          'page_limit': _initialBatchSize,
        });

        final response = _unwrapResponse(responseRaw);
        if (response is List) {
          newPosts = response.map<Map<String, dynamic>>((post) {
            final Map<String, dynamic> convertedPost = {};
            (post as Map).forEach((key, value) {
              convertedPost[key.toString()] = value;
            });
            convertedPost['postId'] = convertedPost['postId']?.toString();
            return convertedPost;
          }).toList();
        } else {
          newPosts = [];
        }

        _offsetFollowing += newPosts.length;
        _hasMoreFollowing = newPosts.isNotEmpty;
      } else {
        final responseRaw = await _supabase.rpc('get_for_you_feed', params: {
          'current_user_id': userId,
          'excluded_users': excludedUsers,
          'page_offset': _offsetForYou,
          'page_limit': _initialBatchSize,
        });

        final response = _unwrapResponse(responseRaw);
        if (response is List) {
          newPosts = response.map<Map<String, dynamic>>((post) {
            final Map<String, dynamic> convertedPost = {};
            (post as Map).forEach((key, value) {
              if (key.toString() == 'postScore') {
                convertedPost['score'] = value;
              } else {
                convertedPost[key.toString()] = value;
              }
            });
            convertedPost['postId'] = convertedPost['postId']?.toString();
            return convertedPost;
          }).toList();
        } else {
          newPosts = [];
        }

        _offsetForYou += newPosts.length;
        _hasMoreForYou = newPosts.isNotEmpty;

        unawaited(() async {
          _nextForYouBatch = await _loadNextForYouBatch();
          _nextBatchLoaded = true;
        }());
      }

      if (!loadMore) {
        _postsBeingPreloaded.clear();
        _postsFullyPreloaded.clear();
        final toPreload =
            newPosts.length > 3 ? newPosts.sublist(0, 3) : newPosts;
        _preloadAllMediaForPosts(toPreload);
      } else {
        _preloadAllMediaForPosts(newPosts);
      }

      for (final post in newPosts) {
        _cachePost(post);
      }

      if (mounted) {
        setState(() {
          if (_selectedTab == 0) {
            _followingPosts =
                loadMore ? [..._followingPosts, ...newPosts] : newPosts;
          } else {
            _forYouPosts = loadMore ? [..._forYouPosts, ...newPosts] : newPosts;
          }
          _isLoadingMore = false;
        });

        unawaited(_bulkFetchUsers(newPosts));

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !loadMore) {
            final currentPage =
                _selectedTab == 1 ? _currentForYouPage : _currentFollowingPage;
            final currentPosts =
                _selectedTab == 1 ? _forYouPosts : _followingPosts;

            _updateVisiblePosts(currentPage);

            if (_selectedTab == 1 && currentPosts.isNotEmpty) {
              final firstPost = currentPosts.first;
              final firstPostId = firstPost['postId']?.toString() ?? '';
              if (firstPostId.isNotEmpty) {
                setState(() {
                  _postVisibility[firstPostId] = true;
                  _currentPlayingPostId = firstPostId;
                  _firstVideoInitialized = false;
                });
                unawaited(_scheduleViewRecording(firstPostId));
              }
            }
          }
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final currentPage =
                _selectedTab == 1 ? _currentForYouPage : _currentFollowingPage;
            final currentPosts =
                _selectedTab == 1 ? _forYouPosts : _followingPosts;
            _updatePostVisibility(currentPage, currentPosts, _selectedTab == 1);
          }
        });
      }
    } catch (e, stack) {
      await _logFeedError(
        operation: '_loadData',
        error: e,
        stack: stack,
        additionalData: {
          'selectedTab': _selectedTab,
          'loadMore': loadMore,
          'userId': currentUserId,
        },
      );
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  void _switchTab(int index) {
    if (_selectedTab == index) return;

    _pauseCurrentVideo();
    _currentPlayingPostId = null;
    _firstVideoInitialized = false;

    for (final controller in _feedVideoControllers.values) {
      controller.dispose();
    }
    _feedVideoControllers.clear();
    _feedVideoControllersInitialized.clear();
    _videoInitializationFutures.clear();
    _loadedImageProviders.clear();
    _imagePreloaded.clear();
    _cachedImageInfo.clear();
    _visiblePosts.clear();
    _postReadyToShow.clear();

    _postsBeingPreloaded.clear();
    _postsFullyPreloaded.clear();

    setState(() {
      _selectedTab = index;
      _isLoading = true;
      _showOverlay = true;
    });

    if (index == 0) {
      _offsetFollowing = 0;
      _followingPosts.clear();
      _hasMoreFollowing = true;
      _currentFollowingPage = 0;

      if (!_followingIdsLoaded) {
        _followingIdsLoaded = true;
        _loadFollowingIds().then((_) => _loadData()).then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      } else {
        _loadData().then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      }
    } else {
      _offsetForYou = 0;
      _forYouPosts.clear();
      _hasMoreForYou = true;
      _currentForYouPage = 0;

      _loadData().then((_) {
        if (mounted) setState(() => _isLoading = false);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _pauseCurrentVideo();
    _currentPlayingPostId = null;
    _firstVideoInitialized = false;
    _followingPageController.dispose();
    _forYouPageController.dispose();
    _interstitialAd?.dispose();
    _unreadCountTimer?.cancel();
    _unreadCountController?.close();
    _delayedCacheUpdateTimer?.cancel();

    for (final controller in _feedVideoControllers.values) {
      try {
        if (controller.value.isInitialized) {
          controller.pause();
          controller.dispose();
        }
      } catch (e) {}
    }
    _feedVideoControllers.clear();
    _feedVideoControllersInitialized.clear();
    _videoInitializationFutures.clear();
    _loadedImageProviders.clear();
    _imagePreloaded.clear();
    _cachedImageInfo.clear();
    _postReadyToShow.clear();

    _postsBeingPreloaded.clear();
    _postsFullyPreloaded.clear();

    super.dispose();
  }

  bool _shouldPostPlayVideo(String postId) {
    return postId == _currentPlayingPostId && (_postVisibility[postId] == true);
  }

  VideoPlayerController? _getVideoControllerForPost(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      return _getPreloadedVideoController(postUrl);
    }
    return null;
  }

  bool _isVideoPreloadedAndReady(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      return _isVideoControllerInitialized(postUrl);
    }
    return false;
  }

  bool _isImagePreloadedAndReady(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    final imageUrls = _getAllImageUrlsFromPost(post);

    if (postUrl.isNotEmpty && _isImageFile(postUrl)) {
      return _imagePreloaded[postUrl] == true &&
          _loadedImageProviders.containsKey(postUrl);
    }

    for (final imageUrl in imageUrls) {
      if (_imagePreloaded[imageUrl] == true &&
          _loadedImageProviders.containsKey(imageUrl)) {
        return true;
      }
    }

    return false;
  }

  Widget _buildMinimalSkeleton(_ColorSet colors) {
    final isDark = colors.backgroundColor == const Color(0xFF121212);
    return FeedSkeleton(isDark: isDark);
  }

  void _navigateToMessages() {
    VideoManager.pauseAllVideos();
    _currentPlayingPostId = null;

    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? userId = userProvider.firebaseUid ?? userProvider.supabaseUid;

    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to view messages')),
      );
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FeedMessages(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final width = MediaQuery.of(context).size.width;

    if (!_essentialUiReady) {
      return _buildMinimalSkeleton(colors);
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      body: Stack(
        children: [
          _buildFeedBody(colors),
          if (width <= webScreenSize)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: Duration(milliseconds: 300),
                child: _buildOverlayContent(colors),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOverlayContent(_ColorSet colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTabItem(1, 'For You', colors),
                const SizedBox(width: 40),
                _buildTabItem(0, 'Following', colors),
              ],
            ),
          ),
          Positioned(
            right: 0,
            child: _buildMessageButton(colors),
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label, _ColorSet colors) {
    final bool isSelected = _selectedTab == index;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        _switchTab(index);
        _showInterstitialAd();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
                fontFamily: 'Inter',
              ),
            ),
            const SizedBox(height: 4),
            Container(
              height: 2,
              width: 60,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageButton(_ColorSet colors) {
    return GestureDetector(
      onTap: _navigateToMessages,
      child: StreamBuilder<int>(
        stream: _unreadCountStream,
        builder: (context, snapshot) {
          final count = snapshot.data ?? 0;
          final formattedCount = _formatMessageCount(count);

          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Material(
                color: Colors.transparent,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  icon: Icon(
                    Icons.message,
                    color: colors.iconColor,
                    size: 24,
                  ),
                  onPressed: _navigateToMessages,
                ),
              ),
              if (count > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(
                      minWidth: 20,
                      minHeight: 20,
                    ),
                    decoration: BoxDecoration(
                      color: colors.cardColor,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        formattedCount,
                        style: TextStyle(
                          color: colors.textColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFeedBody(_ColorSet colors) {
    return SizedBox.expand(
      child: _selectedTab == 1
          ? _buildForYouFeed(colors)
          : _buildFollowingFeed(colors),
    );
  }

  Widget _buildFollowingFeed(_ColorSet colors) {
    if (_isLoading && _followingPosts.isEmpty) {
      return _buildLoadingFeed(colors);
    }
    if (!_isLoading && _followingIds.isEmpty) {
      return _buildNoFollowingMessage(colors);
    }
    return _buildPostsPageView(
        _followingPosts, _followingPageController, colors, false);
  }

  Widget _buildForYouFeed(_ColorSet colors) {
    if (_isLoading && _forYouPosts.isEmpty) {
      return _buildLoadingFeed(colors);
    }

    if (_forYouPosts.isNotEmpty) {
      return _buildPostsPageView(
          _forYouPosts, _forYouPageController, colors, true);
    }

    return _buildLoadingFeed(colors);
  }

  Widget _buildLoadingFeed(_ColorSet colors) {
    final isDark = colors.backgroundColor == const Color(0xFF121212);
    return FeedSkeleton(isDark: isDark);
  }

  Widget _buildNoFollowingMessage(_ColorSet colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Text(
          "Follow users to see their posts here!",
          style: TextStyle(
            color: colors.textColor.withOpacity(0.7),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildPostsPageView(
    List<Map<String, dynamic>> posts,
    PageController controller,
    _ColorSet colors,
    bool isForYou,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification scrollInfo) {
        if (scrollInfo is ScrollUpdateNotification) {
          final currentOffset = scrollInfo.metrics.pixels;
          final scrollDifference = currentOffset - _lastScrollOffset;

          if (scrollDifference > 5 && _showOverlay) {
            setState(() => _showOverlay = false);
          } else if (scrollDifference < -5 && !_showOverlay) {
            setState(() => _showOverlay = true);
          }

          _lastScrollOffset = currentOffset;
        }
        return false;
      },
      child: PageView.builder(
        controller: controller,
        scrollDirection: Axis.vertical,
        itemCount: posts.length + (_isLoadingMore ? 1 : 0),
        onPageChanged: (page) => _onPageChanged(page, isForYou),
        itemBuilder: (ctx, index) {
          if (index >= posts.length) {
            return _buildLoadingIndicator(colors);
          }

          final post = posts[index];
          final postId = post['postId']?.toString() ?? '';
          final postUrl = post['postUrl']?.toString() ?? '';
          final isVisible = _shouldPostPlayVideo(postId);

          final preloadedVideoController = _getVideoControllerForPost(post);
          final isVideoPreloaded = _isVideoPreloadedAndReady(post);
          final isImagePreloaded = _isImagePreloadedAndReady(post);

          return Container(
            width: double.infinity,
            height: double.infinity,
            color: colors.backgroundColor,
            child: PostCard(
              snap: post,
              isVisible: isVisible,
              onCommentTap: () => _openComments(context, post),
              onPostSeen: isForYou ? () => _onPostSeen(postId) : null,
              preloadedVideoController: preloadedVideoController,
              isVideoPreloaded: isVideoPreloaded,
              preloadedImageProvider: _getPreloadedImageProvider(postUrl),
              isImagePreloaded: isImagePreloaded,
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingIndicator(_ColorSet colors) {
    return Center(
      child: CircularProgressIndicator(color: colors.textColor),
    );
  }

  String _formatMessageCount(int count) {
    if (count < 1000) {
      return count.toString();
    } else if (count < 10000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    } else {
      return '${(count ~/ 1000)}k';
    }
  }
}

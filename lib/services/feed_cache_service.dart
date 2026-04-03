import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void unawaited(Future<void> future) {}

// ---------------------------------------------------------------------------
// Dedicated cache managers
// ---------------------------------------------------------------------------

class _ImageCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'feed_image_cache';
  static _ImageCacheManager? _instance;
  static _ImageCacheManager get instance =>
      _instance ??= _ImageCacheManager._();
  _ImageCacheManager._()
      : super(Config(key, stalePeriod: Duration(days: 7), maxNrOfCacheObjects: 300));
}

class _VideoCacheManager extends CacheManager {
  static const key = 'feed_video_cache';
  static _VideoCacheManager? _instance;
  static _VideoCacheManager get instance =>
      _instance ??= _VideoCacheManager._();
  _VideoCacheManager._()
      : super(Config(key, stalePeriod: Duration(days: 3), maxNrOfCacheObjects: 30, fileService: HttpFileService()));
}

// ---------------------------------------------------------------------------
// FeedCacheService with database logging
// ---------------------------------------------------------------------------

class FeedCacheService {
  // SharedPreferences keys
  static const String _cachedForYouPostsKey = 'cached_for_you_posts_v29';
  static const String _seenPostsKey = 'seen_posts';
  static const Duration _cacheValidityDuration = Duration(hours: 24);
  static const String _mediaPreloadedKey = 'media_preloaded_v2';
  static const String _cacheUsedInSessionKey = 'cache_used_in_session';
  static const String _currentSessionHiddenKey = 'current_session_hidden';
  static const String _lastCacheUpdateAttemptKey = 'last_cache_update_attempt';
  static const String _immediatePostsCacheKey = 'immediate_posts_cache_v1';

  static String? _cachedSessionId;
  static String get _currentSessionId =>
      _cachedSessionId ??= '${DateTime.now().millisecondsSinceEpoch}_${UniqueKey().hashCode}';
  static void resetSession() => _cachedSessionId = null;

  static bool _isLoadingCache = false;
  static Completer<List<Map<String, dynamic>>?>? _cacheLoadCompleter;

  // -------------------------------------------------------------------------
  // Database logging helper
  // -------------------------------------------------------------------------
  static Future<void> _logToFastTable({
    required String eventType,
    String? userId,
    int? durationMs,
    String? details,
    Map<String, dynamic>? extra,
  }) async {
    try {
      final supabase = Supabase.instance.client;
      await supabase.from('fast').insert({
        'event_type': eventType,
        'user_id': userId ?? Supabase.instance.client.auth.currentSession?.user.id,
        'timestamp': DateTime.now().toIso8601String(),
        'duration_ms': durationMs,
        'details': details,
        'extra_data': extra,
      });
    } catch (e) {
      // Silently fail – we don't want logging to break caching
      print('⚠️ [Cache] Failed to log to fast table: $e');
    }
  }

  // -------------------------------------------------------------------------
  // 1. Immediate cache (written after first load)
  // -------------------------------------------------------------------------
  static Future<void> cacheCurrentPostsNow(
    List<Map<String, dynamic>> posts,
    String userId,
  ) async {
    final start = DateTime.now();
    if (posts.isEmpty || userId.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final postsToCache = posts.take(3).toList();

      print('📦 [Cache] cacheCurrentPostsNow: saving ${postsToCache.length} posts for user $userId');
      final cacheData = {
        'posts': postsToCache,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'userId': userId,
        'sessionId': _currentSessionId,
      };
      await prefs.setString(_immediatePostsCacheKey, jsonEncode(cacheData));
      unawaited(_downloadAndCacheMedia(postsToCache));

      final duration = DateTime.now().difference(start).inMilliseconds;
      await _logToFastTable(
        eventType: 'immediate_cache_write',
        userId: userId,
        durationMs: duration,
        details: 'Saved ${postsToCache.length} posts',
        extra: {'post_ids': postsToCache.map((p) => p['postId']).toList()},
      );
    } catch (e) {
      print('❌ [Cache] cacheCurrentPostsNow failed: $e');
      await _logToFastTable(
        eventType: 'immediate_cache_write_error',
        userId: userId,
        details: e.toString(),
      );
    }
  }

  static Future<List<Map<String, dynamic>>?> loadImmediatelyCachedPosts(
    String userId,
  ) async {
    final start = DateTime.now();
    if (userId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_immediatePostsCacheKey);
      if (raw == null) {
        print('⚠️ [Cache] loadImmediatelyCachedPosts: no immediate cache found');
        await _logToFastTable(
          eventType: 'immediate_cache_miss',
          userId: userId,
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: 'No cache found',
        );
        return null;
      }

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedUserId = data['userId'] as String? ?? '';
      final timestamp = data['timestamp'] as int? ?? 0;
      final sessionId = data['sessionId'] as String?;
      final age = DateTime.now().millisecondsSinceEpoch - timestamp;

      if (cachedUserId != userId) {
        print('⚠️ [Cache] loadImmediatelyCachedPosts: wrong user');
        await _logToFastTable(
          eventType: 'immediate_cache_wrong_user',
          userId: userId,
          durationMs: DateTime.now().difference(start).inMilliseconds,
        );
        return null;
      }
      if (age > _cacheValidityDuration.inMilliseconds) {
        print('⚠️ [Cache] loadImmediatelyCachedPosts: stale (${age ~/ 3600000}h)');
        await _logToFastTable(
          eventType: 'immediate_cache_stale',
          userId: userId,
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: 'Age in hours: ${age / 3600000}',
        );
        return null;
      }
      if (sessionId != null && sessionId == _currentSessionId) {
        print('⚠️ [Cache] loadImmediatelyCachedPosts: same session');
        await _logToFastTable(
          eventType: 'immediate_cache_same_session',
          userId: userId,
          durationMs: DateTime.now().difference(start).inMilliseconds,
        );
        return null;
      }

      final posts = (data['posts'] as List<dynamic>?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList() ?? [];
      if (posts.isEmpty) return null;

      final duration = DateTime.now().difference(start).inMilliseconds;
      print('✅ [Cache] loadImmediatelyCachedPosts: returning ${posts.length} posts');
      await _logToFastTable(
        eventType: 'immediate_cache_hit',
        userId: userId,
        durationMs: duration,
        details: 'Returned ${posts.length} posts',
        extra: {'post_ids': posts.map((p) => p['postId']).toList()},
      );
      return posts;
    } catch (e) {
      print('❌ [Cache] loadImmediatelyCachedPosts error: $e');
      await _logToFastTable(
        eventType: 'immediate_cache_load_error',
        userId: userId,
        details: e.toString(),
      );
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 2. Video & Image caching with logging
  // -------------------------------------------------------------------------
  static Future<File?> getCachedVideoFile(String videoUrl) async {
    final start = DateTime.now();
    if (videoUrl.isEmpty) return null;
    try {
      final info = await _VideoCacheManager.instance.getFileFromCache(videoUrl);
      if (info != null && info.file.existsSync()) {
        print('🎬 [Cache] Video CACHE HIT: $videoUrl');
        await _logToFastTable(
          eventType: 'video_cache_hit',
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: videoUrl,
        );
        return info.file;
      } else {
        print('🌐 [Cache] Video CACHE MISS: $videoUrl');
        await _logToFastTable(
          eventType: 'video_cache_miss',
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: videoUrl,
        );
      }
    } catch (e) {
      print('❌ [Cache] getCachedVideoFile error: $e');
    }
    return null;
  }

  static Future<File?> cacheVideoFile(String videoUrl) async {
    final start = DateTime.now();
    if (videoUrl.isEmpty) return null;
    try {
      final cached = await getCachedVideoFile(videoUrl);
      if (cached != null) return cached;

      print('📥 [Cache] cacheVideoFile: downloading $videoUrl');
      final file = await _VideoCacheManager.instance.getSingleFile(videoUrl);
      final duration = DateTime.now().difference(start).inMilliseconds;
      print('✅ [Cache] Video downloaded in ${duration}ms');
      await _logToFastTable(
        eventType: 'video_download',
        durationMs: duration,
        details: videoUrl,
      );
      return file.existsSync() ? file : null;
    } catch (e) {
      print('❌ [Cache] cacheVideoFile error: $e');
      return null;
    }
  }

  static Future<File?> getCachedImageFile(String imageUrl) async {
    final start = DateTime.now();
    if (imageUrl.isEmpty) return null;
    try {
      final info = await _ImageCacheManager.instance.getFileFromCache(imageUrl);
      if (info != null && info.file.existsSync()) {
        print('🖼️ [Cache] Image CACHE HIT: $imageUrl');
        await _logToFastTable(
          eventType: 'image_cache_hit',
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: imageUrl,
        );
        return info.file;
      } else {
        print('🌐 [Cache] Image CACHE MISS: $imageUrl');
        await _logToFastTable(
          eventType: 'image_cache_miss',
          durationMs: DateTime.now().difference(start).inMilliseconds,
          details: imageUrl,
        );
      }
    } catch (e) {
      print('❌ [Cache] getCachedImageFile error: $e');
    }
    return null;
  }

  static Future<File?> cacheImageFile(String imageUrl) async {
    final start = DateTime.now();
    if (imageUrl.isEmpty) return null;
    try {
      final cached = await getCachedImageFile(imageUrl);
      if (cached != null) return cached;

      print('📥 [Cache] cacheImageFile: downloading $imageUrl');
      final file = await _ImageCacheManager.instance.getSingleFile(imageUrl);
      final duration = DateTime.now().difference(start).inMilliseconds;
      print('✅ [Cache] Image downloaded in ${duration}ms');
      await _logToFastTable(
        eventType: 'image_download',
        durationMs: duration,
        details: imageUrl,
      );
      return file.existsSync() ? file : null;
    } catch (e) {
      print('❌ [Cache] cacheImageFile error: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 3. Legacy cache (unchanged but with logging)
  // -------------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>?> loadCachedForYouPosts(String userId) async {
    final start = DateTime.now();
    if (_isLoadingCache) {
      if (_cacheLoadCompleter != null) return await _cacheLoadCompleter!.future;
    }
    _isLoadingCache = true;
    _cacheLoadCompleter = Completer<List<Map<String, dynamic>>?>();

    try {
      final prefs = await SharedPreferences.getInstance();
      final currentSessionId = _currentSessionId;
      final cacheUsedInSession = prefs.getBool(_cacheUsedInSessionKey) ?? false;
      if (cacheUsedInSession) {
        print('⚠️ [Cache] loadCachedForYouPosts: already used this session');
        _cacheLoadCompleter!.complete(null);
        return null;
      }

      final cachedData = prefs.getString(_cachedForYouPostsKey);
      if (cachedData != null) {
        final Map<String, dynamic> data = jsonDecode(cachedData);
        final timestamp = data['timestamp'] as int;
        final cachedUserId = data['userId'] as String;
        final cacheSessionId = data['sessionId'] as String?;
        final cacheAge = DateTime.now().millisecondsSinceEpoch - timestamp;

        final isValid = cachedUserId == userId && cacheAge < _cacheValidityDuration.inMilliseconds;
        final isFromCurrentSession = cacheSessionId == currentSessionId;

        if (isFromCurrentSession) {
          print('⚠️ [Cache] loadCachedForYouPosts: cache from current session');
          _cacheLoadCompleter!.complete(null);
          return null;
        }

        if (isValid) {
          final posts = (data['posts'] as List).map((p) => Map<String, dynamic>.from(p)).toList();
          if (posts.isNotEmpty) {
            await prefs.setBool(_cacheUsedInSessionKey, true);
            final duration = DateTime.now().difference(start).inMilliseconds;
            print('✅ [Cache] loadCachedForYouPosts: returning ${posts.length} posts');
            await _logToFastTable(
              eventType: 'legacy_cache_hit',
              userId: userId,
              durationMs: duration,
              details: 'Returned ${posts.length} posts',
            );
            _cacheLoadCompleter!.complete(posts);
            return posts;
          }
        } else {
          print('⚠️ [Cache] loadCachedForYouPosts: invalid cache');
          await _clearCache(userId);
        }
      } else {
        print('⚠️ [Cache] loadCachedForYouPosts: no cache');
        await _logToFastTable(
          eventType: 'legacy_cache_miss',
          userId: userId,
          durationMs: DateTime.now().difference(start).inMilliseconds,
        );
      }
    } catch (e) {
      print('❌ [Cache] loadCachedForYouPosts error: $e');
    } finally {
      _isLoadingCache = false;
      if (!_cacheLoadCompleter!.isCompleted) _cacheLoadCompleter!.complete(null);
      _cacheLoadCompleter = null;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 4. Seen posts tracking (adds log when a post is marked seen)
  // -------------------------------------------------------------------------
  static Future<void> markPostAsSeen(String postId, String userId) async {
    final start = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenPosts = await getSeenPosts(userId);
      seenPosts.add(postId);
      final trimmed = seenPosts.toList();
      if (trimmed.length > 1000) trimmed.removeRange(0, trimmed.length - 1000);
      await prefs.setStringList('${_seenPostsKey}_$userId', trimmed);
      print('👁️ [Cache] Marked post $postId as seen');
      await _logToFastTable(
        eventType: 'post_marked_seen',
        userId: userId,
        durationMs: DateTime.now().difference(start).inMilliseconds,
        details: postId,
      );
    } catch (e) {
      print('❌ [Cache] markPostAsSeen error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // 5. Media download background tasks (already logs inside safe downloads)
  // -------------------------------------------------------------------------
  static Future<void> _downloadAndCacheMedia(List<Map<String, dynamic>> posts) async {
    print('📥 [Cache] Background media download for ${posts.length} posts');
    for (final post in posts) {
      final postUrl = post['postUrl']?.toString() ?? '';
      final profImage = post['profImage']?.toString() ?? '';
      if (postUrl.isNotEmpty) {
        if (_isVideoUrl(postUrl)) unawaited(_safeDownloadVideo(postUrl));
        else if (_isImageUrl(postUrl)) unawaited(_safeDownloadImage(postUrl));
      }
      if (profImage.isNotEmpty && profImage != 'default' && _isImageUrl(profImage)) {
        unawaited(_safeDownloadImage(profImage));
      }
    }
  }

  static Future<void> _safeDownloadImage(String url) async {
    final start = DateTime.now();
    print('🖼️ [Cache] Downloading image: $url');
    try {
      await _ImageCacheManager.instance.getSingleFile(url);
      final duration = DateTime.now().difference(start).inMilliseconds;
      print('✅ [Cache] Image downloaded in ${duration}ms');
      await _logToFastTable(eventType: 'background_image_download', durationMs: duration, details: url);
    } catch (e) {
      print('❌ [Cache] Image download failed: $url - $e');
    }
  }

  static Future<void> _safeDownloadVideo(String url) async {
    final start = DateTime.now();
    print('🎬 [Cache] Downloading video: $url');
    try {
      await _VideoCacheManager.instance.getSingleFile(url);
      final duration = DateTime.now().difference(start).inMilliseconds;
      print('✅ [Cache] Video downloaded in ${duration}ms');
      await _logToFastTable(eventType: 'background_video_download', durationMs: duration, details: url);
    } catch (e) {
      print('❌ [Cache] Video download failed: $url - $e');
    }
  }

  // -------------------------------------------------------------------------
  // 6. Helper methods (unchanged except adding a log for cache clear)
  // -------------------------------------------------------------------------
  static Future<void> clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedForYouPostsKey);
      await prefs.remove(_immediatePostsCacheKey);
      await prefs.remove(_mediaPreloadedKey);
      await prefs.remove(_cacheUsedInSessionKey);
      await prefs.remove(_lastCacheUpdateAttemptKey);
      await prefs.remove('$_currentSessionHiddenKey$userId');
      await _ImageCacheManager.instance.emptyCache();
      await _VideoCacheManager.instance.emptyCache();
      print('🗑️ [Cache] Cache cleared for user $userId');
      await _logToFastTable(eventType: 'cache_cleared', userId: userId);
    } catch (_) {}
  }

  static Future<Set<String>> getSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('${_seenPostsKey}_$userId') ?? [];
      return Set<String>.from(list);
    } catch (_) {
      return <String>{};
    }
  }

  // (Other existing methods: updateCacheAfterScroll, safeCacheUpdate, etc. remain as before
  // but you can add logging similarly if desired. For brevity they are omitted here.
  // The full file would include them unchanged.)

  static bool _isVideoUrl(String url) {
    final l = url.toLowerCase();
    return l.endsWith('.mp4') || l.endsWith('.mov') || l.endsWith('.avi') ||
        l.endsWith('.mkv') || l.endsWith('.webm') || l.endsWith('.m4v') ||
        l.endsWith('.3gp') || l.contains('/video/') || l.contains('video=true');
  }

  static bool _isImageUrl(String url) {
    final l = url.toLowerCase();
    return l.endsWith('.jpg') || l.endsWith('.jpeg') || l.endsWith('.png') ||
        l.endsWith('.gif') || l.endsWith('.webp') || l.endsWith('.bmp') ||
        l.contains('/image/') || l.contains('/images/') || l.contains('type=image') ||
        l.contains('image=true') || l.contains('firebasestorage.googleapis.com') ||
        l.contains('supabase.co/storage');
  }

  static Future<void> _clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedForYouPostsKey);
      await prefs.remove(_immediatePostsCacheKey);
      await prefs.remove(_mediaPreloadedKey);
      await prefs.remove(_cacheUsedInSessionKey);
      await prefs.remove(_lastCacheUpdateAttemptKey);
      await prefs.remove('$_currentSessionHiddenKey$userId');
    } catch (_) {}
  }

  // ... (rest of the legacy methods like cacheForYouPosts, updateCacheAfterScroll, etc.
  // would be placed here exactly as they were, but with optional logging. For space,
  // I'm showing the key parts. In your actual file, keep them unchanged.)
}

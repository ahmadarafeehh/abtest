import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

void unawaited(Future<void> future) {}

class FeedCacheService {
  static const String _cachedForYouPostsKey = 'cached_for_you_posts_v29';
  static const String _seenPostsKey = 'seen_posts';
  static const Duration _cacheValidityDuration = Duration(hours: 24);
  static const String _mediaPreloadedKey = 'media_preloaded_v2';
  static const String _cacheUsedInSessionKey = 'cache_used_in_session';
  static const String _currentSessionHiddenKey = 'current_session_hidden';
  static const String _lastCacheUpdateAttemptKey = 'last_cache_update_attempt';

  // Store session ID once per app session
  static String? _cachedSessionId;

  static String get _currentSessionId {
    if (_cachedSessionId == null) {
      _cachedSessionId =
          '${DateTime.now().millisecondsSinceEpoch}_${UniqueKey().hashCode}';
    }
    return _cachedSessionId!;
  }

  // Clear cached session ID (call this on app restart)
  static void resetSession() {
    _cachedSessionId = null;
  }

  // Prevent concurrent cache loading
  static bool _isLoadingCache = false;
  static Completer<List<Map<String, dynamic>>?>? _cacheLoadCompleter;

  static Future<void> cacheForYouPosts(
      List<Map<String, dynamic>> posts, String userId,
      {List<Map<String, dynamic>>? nextBatchPosts,
      bool forceUpdate = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Check if we recently tried to update cache (prevent rapid updates)
      if (!forceUpdate) {
        final lastUpdateAttempt = prefs.getInt(_lastCacheUpdateAttemptKey) ?? 0;
        final timeSinceLastAttempt =
            DateTime.now().millisecondsSinceEpoch - lastUpdateAttempt;
        final minUpdateInterval = Duration(minutes: 1).inMilliseconds;

        if (timeSinceLastAttempt < minUpdateInterval) {
          return;
        }
      }

      final seenPosts = await getSeenPosts(userId);

      final currentPostIds = posts
          .map((post) => post['postId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      final effectivelySeenPosts = {...seenPosts, ...currentPostIds};

      List<Map<String, dynamic>> allAvailablePosts = [];

      if (nextBatchPosts != null && nextBatchPosts.isNotEmpty) {
        allAvailablePosts.addAll(nextBatchPosts);
      }

      final allUnseenPosts = allAvailablePosts.where((post) {
        final postId = post['postId']?.toString() ?? '';
        return postId.isNotEmpty && !effectivelySeenPosts.contains(postId);
      }).toList();

      List<Map<String, dynamic>> postsToCache = [];

      if (allUnseenPosts.isNotEmpty) {
        postsToCache = allUnseenPosts.take(2).toList();
      } else {
        // Instead of clearing cache when no unseen posts, we should preserve it
        // Check if we already have a valid cache for THIS USER
        final existingCache = prefs.getString(_cachedForYouPostsKey);
        if (existingCache != null) {
          try {
            final data = jsonDecode(existingCache);
            final cachedUserId = data['userId'] as String?;
            final timestamp = data['timestamp'] as int;
            final cacheAge = DateTime.now().millisecondsSinceEpoch - timestamp;

            if (cachedUserId == userId &&
                cacheAge < _cacheValidityDuration.inMilliseconds) {
              return; // Keep existing cache
            } else if (cachedUserId != userId) {
              await _clearCache(userId);
            }
          } catch (e) {}
        }

        return; // Don't update cache, just don't clear it
      }

      if (postsToCache.isNotEmpty) {
        final currentSessionId = _currentSessionId;

        await _markPostsAsHiddenInCurrentSession(postsToCache, userId);

        final cacheData = {
          'posts': postsToCache,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'userId': userId,
          'sessionId': currentSessionId,
        };

        await prefs.setString(_cachedForYouPostsKey, jsonEncode(cacheData));
        await prefs.setBool(_cacheUsedInSessionKey, false);
        await prefs.setInt(
            _lastCacheUpdateAttemptKey, DateTime.now().millisecondsSinceEpoch);

        unawaited(_preloadMediaForPosts(postsToCache));
      }
    } catch (e) {}
  }

  static Future<void> updateCacheAfterScroll(
      String userId,
      List<Map<String, dynamic>> currentBatch,
      List<Map<String, dynamic>>? nextBatch) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenPosts = await getSeenPosts(userId);

      final currentPostIds = currentBatch
          .map((post) => post['postId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final effectivelySeenPosts = {...seenPosts, ...currentPostIds};

      final cachedData = prefs.getString(_cachedForYouPostsKey);

      if (cachedData == null) {
        await cacheForYouPosts(currentBatch, userId, nextBatchPosts: nextBatch);
        return;
      }

      try {
        final data = jsonDecode(cachedData);
        final cachedUserId = data['userId'] as String?;

        // If cache is for a different user, clear it and create new
        if (cachedUserId != userId) {
          await _clearCache(userId);
          await cacheForYouPosts(currentBatch, userId,
              nextBatchPosts: nextBatch);
          return;
        }

        final cachedPosts = (data['posts'] as List)
            .map<Map<String, dynamic>>(
                (post) => Map<String, dynamic>.from(post))
            .toList();

        // Check if any cached posts are now seen
        bool hasSeenCachedPost = false;
        for (final cachedPost in cachedPosts) {
          final cachedPostId = cachedPost['postId']?.toString() ?? '';
          if (effectivelySeenPosts.contains(cachedPostId)) {
            hasSeenCachedPost = true;
          }
        }

        if (!hasSeenCachedPost) {
          return;
        }

        // Only update if we have enough next batch data
        if (nextBatch != null && nextBatch.isNotEmpty) {
          await cacheForYouPosts(currentBatch, userId,
              nextBatchPosts: nextBatch);
        }
      } catch (e) {
        await cacheForYouPosts(currentBatch, userId, nextBatchPosts: nextBatch);
      }
    } catch (e) {}
  }

  static Future<void> _markPostsAsHiddenInCurrentSession(
      List<Map<String, dynamic>> posts, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentSessionHidden = await _getCurrentSessionHiddenPosts(userId);

      for (final post in posts) {
        final postId = post['postId']?.toString();
        if (postId != null && postId.isNotEmpty) {
          currentSessionHidden.add(postId);
        }
      }

      await prefs.setStringList(
          '$_currentSessionHiddenKey$userId', currentSessionHidden.toList());
    } catch (e) {}
  }

  static Future<Set<String>> _getCurrentSessionHiddenPosts(
      String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenPostsList =
          prefs.getStringList('$_currentSessionHiddenKey$userId') ?? [];
      return Set<String>.from(hiddenPostsList);
    } catch (e) {
      return <String>{};
    }
  }

  static Future<void> clearCurrentSessionHiddenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_currentSessionHiddenKey$userId');
    } catch (e) {}
  }

  static Future<List<Map<String, dynamic>>> filterOutCurrentSessionHiddenPosts(
      List<Map<String, dynamic>> posts, String userId) async {
    try {
      final currentSessionHidden = await _getCurrentSessionHiddenPosts(userId);
      final filteredPosts = posts.where((post) {
        final postId = post['postId']?.toString() ?? '';
        final isHidden = currentSessionHidden.contains(postId);
        return postId.isNotEmpty && !isHidden;
      }).toList();

      return filteredPosts;
    } catch (e) {
      return posts;
    }
  }

  static Future<void> _preloadMediaForPosts(
      List<Map<String, dynamic>> posts) async {
    try {
      for (final post in posts) {
        final mediaUrl = post['postUrl']?.toString();
        final postId = post['postId']?.toString() ?? 'no-id';

        if (mediaUrl != null && mediaUrl.isNotEmpty) {
          unawaited(_preloadSingleMedia(mediaUrl, postId).catchError((e) {}));
        }
      }
    } catch (e) {}
  }

  static Future<void> _preloadSingleMedia(
      String mediaUrl, String postId) async {
    const int maxRetries = 2;
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        attempt++;
        final file = await DefaultCacheManager().getSingleFile(mediaUrl);
        return;
      } catch (e) {
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 1));
        } else {
          rethrow;
        }
      }
    }
  }

  static Future<List<Map<String, dynamic>>?> loadCachedForYouPosts(
      String userId) async {
    // Prevent concurrent cache loading
    if (_isLoadingCache) {
      if (_cacheLoadCompleter != null) {
        return await _cacheLoadCompleter!.future;
      }
    }

    _isLoadingCache = true;
    _cacheLoadCompleter = Completer<List<Map<String, dynamic>>?>();

    try {
      final prefs = await SharedPreferences.getInstance();
      final currentSessionId = _currentSessionId;
      final cacheUsedInSession = prefs.getBool(_cacheUsedInSessionKey) ?? false;

      if (cacheUsedInSession) {
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

        final isValid = cachedUserId == userId &&
            cacheAge < _cacheValidityDuration.inMilliseconds;
        final isFromCurrentSession = cacheSessionId == currentSessionId;

        if (isFromCurrentSession) {
          _cacheLoadCompleter!.complete(null);
          return null;
        }

        if (isValid) {
          final List<dynamic> postsData = data['posts'];
          final cachedPosts = postsData.map<Map<String, dynamic>>((post) {
            return Map<String, dynamic>.from(post);
          }).toList();

          if (cachedPosts.isNotEmpty) {
            await prefs.setBool(_cacheUsedInSessionKey, true);
            _cacheLoadCompleter!.complete(cachedPosts);
            return cachedPosts;
          }
        } else {
          await _clearCache(userId);
        }
      }
    } catch (e) {
    } finally {
      _isLoadingCache = false;
      if (!_cacheLoadCompleter!.isCompleted) {
        _cacheLoadCompleter!.complete(null);
      }
      _cacheLoadCompleter = null;
    }

    return null;
  }

  static Future<bool> isMediaPreloaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isPreloaded = prefs.getBool(_mediaPreloadedKey) ?? false;
      return isPreloaded;
    } catch (e) {
      return false;
    }
  }

  static Future<void> clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedForYouPostsKey);
      await prefs.remove(_mediaPreloadedKey);
      await prefs.remove(_cacheUsedInSessionKey);
      await prefs.remove(_lastCacheUpdateAttemptKey);
      await prefs.remove('$_currentSessionHiddenKey$userId');

      await DefaultCacheManager().emptyCache();
    } catch (e) {}
  }

  static Future<Set<String>> getSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenPostsList =
          prefs.getStringList('${_seenPostsKey}_$userId') ?? [];
      return Set<String>.from(seenPostsList);
    } catch (e) {
      return <String>{};
    }
  }

  static Future<void> markPostAsSeen(String postId, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenPosts = await getSeenPosts(userId);
      seenPosts.add(postId);

      final trimmedSeenPosts = seenPosts.toList();
      if (trimmedSeenPosts.length > 1000) {
        trimmedSeenPosts.removeRange(0, trimmedSeenPosts.length - 1000);
      }

      await prefs.setStringList('${_seenPostsKey}_$userId', trimmedSeenPosts);
    } catch (e) {}
  }

  static Future<void> clearSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_seenPostsKey}_$userId');
    } catch (e) {}
  }

  static Future<void> clearCurrentSessionSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionId = _currentSessionId;
      await prefs.remove('${_seenPostsKey}_${sessionId}_$userId');
    } catch (e) {}
  }

  static Future<void> _clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachedForYouPostsKey);
      await prefs.remove(_mediaPreloadedKey);
      await prefs.remove(_cacheUsedInSessionKey);
      await prefs.remove(_lastCacheUpdateAttemptKey);
      await prefs.remove('$_currentSessionHiddenKey$userId');
    } catch (e) {}
  }

  static Future<void> resetSessionFlag(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cacheUsedInSessionKey, false);
    await clearCurrentSessionHiddenPosts(userId);
  }

  // New method to safely update cache when we have good data
  static Future<void> safeCacheUpdate(
      String userId,
      List<Map<String, dynamic>> currentBatch,
      List<Map<String, dynamic>> nextBatch) async {
    if (nextBatch.isEmpty) {
      return;
    }

    // Wait a bit to ensure data is stable
    await Future.delayed(Duration(milliseconds: 500));

    // Check if we have enough unseen posts
    final seenPosts = await getSeenPosts(userId);
    final currentPostIds = currentBatch
        .map((post) => post['postId']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final effectivelySeenPosts = {...seenPosts, ...currentPostIds};

    final unseenPosts = nextBatch.where((post) {
      final postId = post['postId']?.toString() ?? '';
      return postId.isNotEmpty && !effectivelySeenPosts.contains(postId);
    }).toList();

    if (unseenPosts.isNotEmpty) {
      await cacheForYouPosts(currentBatch, userId,
          nextBatchPosts: nextBatch, forceUpdate: true);
    }
  }
}

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/screens/Profile_page/image_screen.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/providers/user_provider.dart';

class _SearchColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color dividerColor;
  final Color progressIndicatorColor;
  final Color errorColor;
  final Color gridBackgroundColor;
  final Color gridItemBackgroundColor;
  final Color appBarBackgroundColor;
  final Color hintTextColor;
  final Color borderColor;
  final Color focusedBorderColor;
  final Color skeletonColor;
  final Color avatarBackgroundColor;

  _SearchColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.dividerColor,
    required this.progressIndicatorColor,
    required this.errorColor,
    required this.gridBackgroundColor,
    required this.gridItemBackgroundColor,
    required this.appBarBackgroundColor,
    required this.hintTextColor,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.skeletonColor,
    required this.avatarBackgroundColor,
  });
}

class _SearchDarkColors extends _SearchColorSet {
  _SearchDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF121212),
          iconColor: const Color(0xFFd9d9d9),
          dividerColor: const Color(0xFF333333),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          errorColor: Colors.red,
          gridBackgroundColor: const Color(0xFF121212),
          gridItemBackgroundColor: const Color(0xFF333333),
          appBarBackgroundColor: const Color(0xFF121212),
          hintTextColor: const Color(0xFF666666),
          borderColor: const Color(0xFF333333),
          focusedBorderColor: const Color(0xFFd9d9d9),
          skeletonColor: const Color(0xFF333333).withOpacity(0.6),
          avatarBackgroundColor: const Color(0xFF333333),
        );
}

class _SearchLightColors extends _SearchColorSet {
  _SearchLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
          dividerColor: Colors.grey[300]!,
          progressIndicatorColor: Colors.grey[700]!,
          errorColor: Colors.red,
          gridBackgroundColor: Colors.grey[100]!,
          gridItemBackgroundColor: Colors.grey[300]!,
          appBarBackgroundColor: Colors.grey[100]!,
          hintTextColor: Colors.grey[600]!,
          borderColor: Colors.grey[400]!,
          focusedBorderColor: Colors.black,
          skeletonColor: Colors.grey[300]!.withOpacity(0.6),
          avatarBackgroundColor: Colors.grey[300]!,
        );
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({Key? key}) : super(key: key);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController searchController = TextEditingController();
  final _supabase = Supabase.instance.client;
  bool isShowUsers = false;
  bool _isSearchFocused = false;
  String? currentUserId;

  List<Map<String, dynamic>> _allPosts = [];
  Set<String> blockedUsersSet = {};
  bool _isLoading = true;

  // Pagination helpers
  int _offset = 0;
  bool _isLoadingMore = false;
  bool _hasMorePosts = true;
  bool _isFirstLoad = true;

  final int _initialPostsLimit = 12;
  final int _subsequentPostsLimit = 6;
  final int _initialPostsToShow = 12;

  final ScrollController _scrollController = ScrollController();

  List<String> _rotatedSuggestedUsers = [];
  final Random _random = Random();

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  final Map<String, VideoPlayerController> _avatarVideoControllers = {};
  final Map<String, bool> _avatarVideoControllersInitialized = {};

  _SearchColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? _SearchDarkColors()
        : _SearchLightColors();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoadingMore &&
          _hasMorePosts &&
          !isShowUsers) {
        _loadMorePosts();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && currentUserId == null) {
      currentUserId = userProvider.firebaseUid;
      if (!_isLoading) _initData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        currentUserId == null) {
      currentUserId = userProvider.supabaseUid;
      if (!_isLoading) _initData();
    }

    if (currentUserId != null && _isLoading) _initData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    }
  }

  void _pauseAllVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
    for (final c in _avatarVideoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    searchController.dispose();
    _scrollController.dispose();
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    for (final c in _avatarVideoControllers.values) {
      c.dispose();
    }
    _avatarVideoControllers.clear();
    _avatarVideoControllersInitialized.clear();
    super.dispose();
  }

  // ========== VIDEO CONTROLLERS ==========
  Future<void> _initializeVideoController(String videoUrl) async {
    if (_videoControllers.containsKey(videoUrl) ||
        _videoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _videoControllers[videoUrl] = controller;
      _videoControllersInitialized[videoUrl] = false;
      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_videoControllersInitialized[videoUrl]!) {
          _videoControllersInitialized[videoUrl] = true;
          _configureVideoLoop(controller);
          if (mounted) setState(() {});
        }
      });
      await controller.initialize();
      await controller.setVolume(0.0);
    } catch (_) {
      _videoControllers.remove(videoUrl)?.dispose();
      _videoControllersInitialized.remove(videoUrl);
    }
  }

  Future<void> _initializeAvatarVideoController(String videoUrl) async {
    if (_avatarVideoControllers.containsKey(videoUrl) ||
        _avatarVideoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _avatarVideoControllers[videoUrl] = controller;
      _avatarVideoControllersInitialized[videoUrl] = false;
      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_avatarVideoControllersInitialized[videoUrl]!) {
          _avatarVideoControllersInitialized[videoUrl] = true;
          _configureVideoLoop(controller);
          if (mounted) setState(() {});
        }
      });
      await controller.initialize();
      await controller.setVolume(0.0);
    } catch (_) {
      _avatarVideoControllers.remove(videoUrl)?.dispose();
      _avatarVideoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureVideoLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) controller.seekTo(Duration.zero);
      }
    });
    controller.play();
  }

  VideoPlayerController? _getVideoController(String url) =>
      _videoControllers[url];
  bool _isVideoControllerInitialized(String url) =>
      _videoControllersInitialized[url] == true;
  VideoPlayerController? _getAvatarVideoController(String url) =>
      _avatarVideoControllers[url];
  bool _isAvatarVideoControllerInitialized(String url) =>
      _avatarVideoControllersInitialized[url] == true;

  bool _isVideoFile(String url) {
    if (url.isEmpty) return false;
    final l = url.toLowerCase();
    return l.endsWith('.mp4') ||
        l.endsWith('.mov') ||
        l.endsWith('.avi') ||
        l.endsWith('.wmv') ||
        l.endsWith('.flv') ||
        l.endsWith('.mkv') ||
        l.endsWith('.webm') ||
        l.endsWith('.m4v') ||
        l.endsWith('.3gp') ||
        l.contains('/video/') ||
        l.contains('video=true');
  }

  Widget _buildVideoPlayer(String videoUrl, _SearchColorSet colors) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        color: colors.gridItemBackgroundColor,
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }
    return AspectRatio(
      aspectRatio: 0.75,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: colors.gridItemBackgroundColor,
          child: Stack(fit: StackFit.expand, children: [
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildAvatarVideoPlayer(String videoUrl, _SearchColorSet colors) {
    final controller = _getAvatarVideoController(videoUrl);
    final isInitialized = _isAvatarVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: colors.avatarBackgroundColor),
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor, strokeWidth: 2.0)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildUserAvatar(String? photoUrl, _SearchColorSet colors) {
    final url = photoUrl?.toString() ?? '';
    final isDefault = url.isEmpty || url == 'default';
    final isVideo = !isDefault && _isVideoFile(url);

    if (isDefault) {
      return CircleAvatar(
        backgroundColor: colors.avatarBackgroundColor,
        radius: 20,
        child: Icon(Icons.account_circle, size: 40, color: colors.iconColor),
      );
    }
    if (isVideo) {
      if (!_avatarVideoControllers.containsKey(url)) {
        _initializeAvatarVideoController(url);
      }
      return _buildAvatarVideoPlayer(url, colors);
    }
    return CircleAvatar(
      backgroundColor: colors.avatarBackgroundColor,
      radius: 20,
      backgroundImage: NetworkImage(url),
    );
  }

  // ========== DATA LOADING ==========
  Future<void> _initData() async {
    if (currentUserId == null) {
      setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);

    await Future.wait([
      _loadBlockedUsers(),
      _fetchPosts(),
    ]);
    _rotateSuggestedUsers();
    setState(() => _isLoading = false);
  }

  Future<void> _loadBlockedUsers() async {
    if (currentUserId == null) {
      blockedUsersSet = {};
      return;
    }
    try {
      final response = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId!)
          .single();
      final blockedUsers = response['blockedUsers'] as List<dynamic>?;
      blockedUsersSet = Set<String>.from(blockedUsers ?? []);
    } catch (_) {
      blockedUsersSet = {};
    }
  }

  Future<void> _fetchPosts() async {
    if (currentUserId == null) {
      _allPosts = [];
      _hasMorePosts = false;
      _isFirstLoad = false;
      return;
    }
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final postsLimit =
          _isFirstLoad ? _initialPostsLimit : _subsequentPostsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': 0,
        'page_limit': postsLimit,
      });

      if (response is List && response.isNotEmpty) {
        _allPosts = response.map<Map<String, dynamic>>((post) {
          final Map<String, dynamic> converted = {};
          (post as Map).forEach((k, v) => converted[k.toString()] = v);
          return converted;
        }).toList();

        for (final post in _allPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }

        _offset = _allPosts.length;
        _hasMorePosts = _allPosts.length == postsLimit;
        _isFirstLoad = false;
      } else {
        _allPosts = [];
        _hasMorePosts = false;
        _isFirstLoad = false;
      }
    } catch (_) {
      _allPosts = [];
      _hasMorePosts = false;
      _isFirstLoad = false;
    }
  }

  Future<void> _loadMorePosts() async {
    if (!_hasMorePosts || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final postsLimit = _subsequentPostsLimit;
      final pageNumber = _offset ~/ postsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': pageNumber,
        'page_limit': postsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts = response.map<Map<String, dynamic>>((post) {
          final Map<String, dynamic> converted = {};
          (post as Map).forEach((k, v) => converted[k.toString()] = v);
          return converted;
        }).toList();

        for (final post in newPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }

        setState(() {
          _allPosts.addAll(newPosts);
          _offset += newPosts.length;
          _hasMorePosts = newPosts.length == _subsequentPostsLimit;
        });
      } else {
        setState(() => _hasMorePosts = false);
      }
    } catch (_) {
      setState(() => _hasMorePosts = false);
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  void _rotateSuggestedUsers() {
    if (currentUserId == null) {
      _rotatedSuggestedUsers = [];
      return;
    }
    final suggestedUserIds = _allPosts
        .map((p) => p['uid']?.toString())
        .whereType<String>()
        .where((uid) => !blockedUsersSet.contains(uid) && uid != currentUserId)
        .toSet()
        .toList();

    if (suggestedUserIds.isEmpty) {
      _rotatedSuggestedUsers = [];
      return;
    }
    suggestedUserIds.shuffle(_random);
    _rotatedSuggestedUsers = suggestedUserIds.take(5).toList();
  }

  void _navigateToProfile(String uid) {
    if (uid.isEmpty) return;
    _pauseAllVideos();
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => ProfileScreen(uid: uid)))
        .then((_) {
      if (mounted) {
        setState(() {
          isShowUsers = false;
          searchController.clear();
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> _fetchUsersByIds(
      List<String> userIds) async {
    if (userIds.isEmpty) return [];
    try {
      final response =
          await _supabase.from('users').select().inFilter('uid', userIds);
      return List<Map<String, dynamic>>.from(response).where((u) {
        final id = u['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(id) && id != currentUserId;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    try {
      final response = await _supabase
          .from('users')
          .select()
          .ilike('username', '$query%')
          .limit(15);
      return List<Map<String, dynamic>>.from(response).where((u) {
        final id = u['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(id) && id != currentUserId;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ========== SKELETONS ==========
  Widget _buildPostsGridSkeleton(_SearchColorSet colors) {
    return ListView(
      padding: const EdgeInsets.all(8.0),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Row(children: [
              Expanded(child: Divider(color: colors.dividerColor)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Container(
                  height: 20,
                  width: 180,
                  decoration: BoxDecoration(
                      color: colors.skeletonColor,
                      borderRadius: BorderRadius.circular(4)),
                ),
              ),
              Expanded(child: Divider(color: colors.dividerColor)),
            ]),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8.0,
                mainAxisSpacing: 8.0,
                childAspectRatio: 0.75),
            itemCount: 3,
            itemBuilder: (_, __) => _buildPostSkeleton(colors),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Divider(color: colors.dividerColor),
          ),
        ]),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8.0,
              mainAxisSpacing: 8.0,
              childAspectRatio: 0.75),
          itemCount: _initialPostsToShow - 3,
          itemBuilder: (_, __) => _buildPostSkeleton(colors),
        ),
      ],
    );
  }

  Widget _buildPostSkeleton(_SearchColorSet colors) => Container(
        decoration: BoxDecoration(
            color: colors.skeletonColor,
            borderRadius: BorderRadius.circular(8)),
      );

  Widget _buildSuggestedUsersSkeleton(_SearchColorSet colors) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.all(12.0),
        child: Container(
          height: 20,
          width: 140,
          decoration: BoxDecoration(
              color: colors.skeletonColor,
              borderRadius: BorderRadius.circular(4)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 8),
          itemCount: 5,
          itemBuilder: (_, __) => _buildUserSkeleton(colors),
        ),
      ),
    ]);
  }

  Widget _buildUserSkeleton(_SearchColorSet colors) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(backgroundColor: colors.skeletonColor, radius: 20),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            height: 14,
            width: 120,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 12,
            width: 80,
            decoration: BoxDecoration(
                color: colors.skeletonColor.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }

  Widget _buildUserSearchSkeleton(_SearchColorSet colors) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 5,
      itemBuilder: (_, __) => _buildUserSkeleton(colors),
    );
  }

  // ========== BUILD ==========
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      if (userProvider.firebaseUid != null && currentUserId == null) {
        currentUserId = userProvider.firebaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      } else if (userProvider.firebaseUid == null &&
          userProvider.supabaseUid != null &&
          currentUserId == null) {
        currentUserId = userProvider.supabaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      }
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        backgroundColor: colors.appBarBackgroundColor,
        toolbarHeight: 80,
        elevation: 0,
        iconTheme: IconThemeData(color: colors.iconColor),
        title: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: SizedBox(
            height: 48,
            child: TextFormField(
              controller: searchController,
              style: TextStyle(color: colors.textColor),
              decoration: InputDecoration(
                hintText: 'Search for a user...',
                hintStyle: TextStyle(color: colors.hintTextColor),
                filled: true,
                fillColor: colors.cardColor,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.borderColor),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: colors.focusedBorderColor, width: 2),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
              onTap: () {
                if (searchController.text.trim().isEmpty) {
                  setState(() {
                    isShowUsers = false;
                    _isSearchFocused = true;
                  });
                }
              },
              onChanged: (value) {
                setState(() {
                  isShowUsers = value.trim().isNotEmpty;
                  _isSearchFocused = false;
                });
              },
              onFieldSubmitted: (_) {
                setState(() {
                  isShowUsers = true;
                  _isSearchFocused = false;
                });
              },
            ),
          ),
        ),
      ),
      body: _isLoading
          ? _buildEnhancedSkeletonLoading(colors)
          : Column(children: [
              Expanded(
                child: _isSearchFocused && searchController.text.trim().isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(top: 15.0),
                        child: _buildSuggestedUsers(colors))
                    : isShowUsers
                        ? Padding(
                            padding: const EdgeInsets.only(top: 15.0),
                            child: _buildUserSearch(colors))
                        : _buildPostsGrid(colors),
              ),
            ]),
    );
  }

  Widget _buildEnhancedSkeletonLoading(_SearchColorSet colors) {
    return Column(children: [
      Expanded(
        child: _isSearchFocused && searchController.text.trim().isEmpty
            ? Padding(
                padding: const EdgeInsets.only(top: 15.0),
                child: _buildSuggestedUsersSkeleton(colors))
            : isShowUsers
                ? Padding(
                    padding: const EdgeInsets.only(top: 15.0),
                    child: _buildUserSearchSkeleton(colors))
                : _buildPostsGridSkeleton(colors),
      ),
    ]);
  }

  Widget _buildSuggestedUsers(_SearchColorSet colors) {
    if (_rotatedSuggestedUsers.isEmpty) {
      return Center(
          child: Text('No suggestions available.',
              style: TextStyle(color: colors.textColor)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.all(12.0),
        child: Text('Suggested users',
            style: TextStyle(
                color: colors.textColor.withOpacity(0.7),
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      ),
      Expanded(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _fetchUsersByIds(_rotatedSuggestedUsers),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildSuggestedUsersSkeleton(colors);
            }
            final users = snapshot.data ?? [];
            if (users.isEmpty) {
              return Center(
                  child: Text('No suggestions found.',
                      style: TextStyle(color: colors.textColor)));
            }
            return ListView.builder(
              padding: const EdgeInsets.only(top: 8),
              itemCount: users.length,
              itemBuilder: (context, index) {
                final user = users[index];
                final userId = user['uid'] as String? ?? '';
                final photoUrl = user['photoUrl']?.toString() ?? '';
                return ListTile(
                  onTap: () => _navigateToProfile(userId),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: _buildUserAvatar(photoUrl, colors),
                  title: VerifiedUsernameWidget(
                    username: user['username']?.toString() ?? 'Unknown',
                    uid: userId,
                    style: TextStyle(color: colors.textColor),
                  ),
                );
              },
            );
          },
        ),
      ),
    ]);
  }

  Widget _buildUserSearch(_SearchColorSet colors) {
    final query = searchController.text.trim();
    if (query.isEmpty) {
      return Center(
          child: Text('Please enter a username.',
              style: TextStyle(color: colors.textColor)));
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _searchUsers(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildUserSearchSkeleton(colors);
        }
        final users = snapshot.data ?? [];
        if (users.isEmpty) {
          return Center(
              child: Text('No users found.',
                  style: TextStyle(color: colors.textColor)));
        }
        return ListView.builder(
          padding: const EdgeInsets.only(top: 8),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            final userId = user['uid'] as String? ?? '';
            final photoUrl = user['photoUrl']?.toString() ?? '';
            return ListTile(
              onTap: () => _navigateToProfile(userId),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: _buildUserAvatar(photoUrl, colors),
              title: VerifiedUsernameWidget(
                username: user['username']?.toString() ?? 'Unknown',
                uid: userId,
                style: TextStyle(color: colors.textColor),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPostsGrid(_SearchColorSet colors) {
    if (_allPosts.isEmpty) {
      return Center(
          child: Text('No posts found.',
              style: TextStyle(color: colors.textColor)));
    }

    final topPosts =
        _allPosts.length >= 3 ? _allPosts.sublist(0, 3) : _allPosts;
    final remainingPosts =
        _allPosts.length > 3 ? _allPosts.sublist(3) : <Map<String, dynamic>>[];

    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (scrollInfo.metrics.extentAfter < 500 &&
              !_isLoadingMore &&
              _hasMorePosts &&
              !isShowUsers) {
            _loadMorePosts();
          }
          return false;
        },
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(8.0),
          children: [
            if (topPosts.isNotEmpty)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  child: Row(children: [
                    Expanded(child: Divider(color: colors.dividerColor)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(
                        'Top posts for this week 🏆',
                        style: TextStyle(
                            color: colors.textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                      ),
                    ),
                    Expanded(child: Divider(color: colors.dividerColor)),
                  ]),
                ),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 0.75,
                      crossAxisSpacing: 8.0,
                      mainAxisSpacing: 8.0),
                  itemCount: topPosts.length,
                  itemBuilder: (context, index) {
                    final post = topPosts[index];
                    return _buildPostItem(
                        post, post['postUrl']?.toString() ?? '', colors, true);
                  },
                ),
                if (remainingPosts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                    child: Divider(color: colors.dividerColor),
                  ),
              ]),
            if (remainingPosts.isNotEmpty)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.75,
                    crossAxisSpacing: 8.0,
                    mainAxisSpacing: 8.0),
                itemCount: remainingPosts.length,
                itemBuilder: (context, index) {
                  final post = remainingPosts[index];
                  return _buildPostItem(
                      post, post['postUrl']?.toString() ?? '', colors, false);
                },
              ),
          ],
        ),
      ),
      if (_isLoadingMore)
        Positioned(
          bottom: 8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.backgroundColor.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor),
            ),
          ),
        ),
    ]);
  }

  Widget _buildPostItem(Map<String, dynamic> post, String postUrl,
      _SearchColorSet colors, bool isTopPost) {
    final isVideo = _isVideoFile(postUrl);
    if (isVideo) _initializeVideoController(postUrl);

    return InkWell(
      onTap: () async {
        final userId = post['uid']?.toString() ?? '';
        if (userId.isEmpty) return;
        _pauseAllVideos();
        final user = await _fetchUserById(userId);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewScreen(
              imageUrl: postUrl,
              postId: post['postId']?.toString() ?? '',
              description: post['description']?.toString() ?? '',
              userId: userId,
              username: user?['username']?.toString() ?? '',
              profImage: user?['photoUrl']?.toString() ?? '',
              datePublished: post['datePublished']?.toString() ?? '',
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: isVideo ? colors.gridItemBackgroundColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isTopPost ? Border.all(color: Colors.amber, width: 2) : null,
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(children: [
          // ── media ──────────────────────────────────────────────────────
          if (postUrl.isNotEmpty)
            isVideo
                ? _buildVideoPlayer(postUrl, colors)
                : AspectRatio(
                    aspectRatio: 0.75,
                    child: Image.network(
                      postUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Center(
                            child: CircularProgressIndicator(
                                color: colors.progressIndicatorColor));
                      },
                      errorBuilder: (_, __, ___) => Container(
                        color: colors.gridItemBackgroundColor,
                        child:
                            Icon(Icons.broken_image, color: colors.iconColor),
                      ),
                    ),
                  )
          else
            Container(
              color: colors.gridItemBackgroundColor,
              child: Icon(Icons.broken_image, color: colors.iconColor),
            ),

          // ── trophy badge (top posts) ────────────────────────────────────
          if (isTopPost)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    shape: BoxShape.circle),
                child: const Icon(Icons.emoji_events,
                    color: Colors.amber, size: 16),
              ),
            ),
        ]),
      ),
    );
  }

  Future<Map<String, dynamic>?> _fetchUserById(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final response = await _supabase
          .from('users')
          .select()
          .eq('uid', userId)
          .maybeSingle();
      return response as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }
}

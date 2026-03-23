// lib/screens/edit_profile_screen.dart
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:image_picker/image_picker.dart';
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/services/firebase_supabase_service.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:video_trimmer/video_trimmer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import 'package:Ratedly/providers/user_provider.dart';

// Define color schemes for both themes at top level
class _EditProfileColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color borderColor;
  final Color hintTextColor;
  final Color progressIndicatorColor;
  final Color dialogBackgroundColor;
  final Color dialogTextColor;

  _EditProfileColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.borderColor,
    required this.hintTextColor,
    required this.progressIndicatorColor,
    required this.dialogBackgroundColor,
    required this.dialogTextColor,
  });
}

class _EditProfileDarkColors extends _EditProfileColorSet {
  _EditProfileDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          buttonBackgroundColor: const Color(0xFF333333),
          buttonTextColor: const Color(0xFFd9d9d9),
          borderColor: const Color(0xFFd9d9d9),
          hintTextColor: const Color(0xFFd9d9d9).withOpacity(0.7),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          dialogBackgroundColor: const Color(0xFF333333),
          dialogTextColor: const Color(0xFFd9d9d9),
        );
}

class _EditProfileLightColors extends _EditProfileColorSet {
  _EditProfileLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.white,
          cardColor: Colors.grey[200]!,
          iconColor: Colors.black,
          buttonBackgroundColor: Colors.grey[300]!,
          buttonTextColor: Colors.black,
          borderColor: Colors.black,
          hintTextColor: Colors.black.withOpacity(0.7),
          progressIndicatorColor: Colors.black,
          dialogBackgroundColor: Colors.grey[200]!,
          dialogTextColor: Colors.black,
        );
}

class EditProfileScreen extends StatefulWidget {
  // ── FIX: accept uid so we never rely on FirebaseAuth ──
  final String? uid;
  const EditProfileScreen({Key? key, this.uid}) : super(key: key);

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController _bioController = TextEditingController();
  Uint8List? _image;
  File? _videoFile;
  bool _isLoading = false;
  bool _isVideo = false;
  String? _initialPhotoUrl;
  String? _currentPhotoUrl;
  final supabase.SupabaseClient _supabase = supabase.Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();
  bool _hasAgreedToWarning = false;

  // Video trimming variables
  final Trimmer _trimmer = Trimmer();
  bool _isTrimming = false;
  double _startValue = 0.0;
  double _endValue = 0.0;
  bool _isPlaying = false;
  bool _progressVisibility = false;

  // User data for username display
  String? _username;
  String? _countryCode;
  bool _isVerified = false;

  // Track the picked file name
  String? _pickedFileName;

  // Video player controller for profile video
  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;

  // Track if user wants to remove current profile media
  bool _shouldRemoveCurrentMedia = false;

  // ── Resolved UID (widget param → UserProvider → Supabase session) ──
  String? get _resolvedUid {
    if (widget.uid != null && widget.uid!.isNotEmpty) return widget.uid;
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final providerUid = userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (providerUid != null && providerUid.isNotEmpty) return providerUid;
    return _supabase.auth.currentUser?.id;
  }

  // Helper method to get the appropriate color scheme
  _EditProfileColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _EditProfileDarkColors() : _EditProfileLightColors();
  }

  // Helper methods to identify photo types
  bool _isGooglePhoto(String? url) {
    if (url == null || url == 'default') return false;
    return url.contains('googleusercontent.com') ||
        url.contains('lh3.googleusercontent.com');
  }

  bool _isSupabasePhoto(String? url) {
    if (url == null || url == 'default') return false;
    return url.contains('supabase.co/storage');
  }

  // Check if URL is a video (by extension)
  bool _isVideoUrl(String? url) {
    if (url == null || url == 'default') return false;
    final urlLower = url.toLowerCase();
    return urlLower.endsWith('.mp4') ||
        urlLower.endsWith('.mov') ||
        urlLower.endsWith('.avi') ||
        urlLower.endsWith('.wmv') ||
        urlLower.endsWith('.flv') ||
        urlLower.endsWith('.mkv') ||
        urlLower.endsWith('.webm') ||
        urlLower.endsWith('.m4v') ||
        urlLower.endsWith('.3gp') ||
        urlLower.contains('/video/') ||
        urlLower.contains('video=true');
  }

  Widget _buildDefaultAvatar(_EditProfileColorSet colors) {
    return Center(
      child: Icon(
        Icons.account_circle,
        size: 96,
        color: colors.iconColor,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _checkIfUserAgreed();
  }

  @override
  void dispose() {
    _trimmer.dispose();
    _bioController.dispose();
    if (_profileVideoController != null) {
      _profileVideoController!.dispose();
    }
    super.dispose();
  }

  Future<void> _checkIfUserAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hasAgreedToWarning = prefs.getBool('hasAgreedToProfileWarning') ?? false;
    });
  }

  Future<void> _saveUserAgreement() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasAgreedToProfileWarning', true);
    setState(() {
      _hasAgreedToWarning = true;
    });
  }

  Future<void> _showWarningDialog() async {
    if (_hasAgreedToWarning) {
      _showGalleryOptions();
      return;
    }

    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: colors.cardColor,
          title: Text(
            'Profile Picture Guidelines',
            style: TextStyle(
              color: colors.textColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text:
                      'Using inappropriate content as your profile picture will get your device ',
                  style: TextStyle(color: colors.textColor),
                ),
                TextSpan(
                  text: 'permanently banned',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(
                  text: '.',
                  style: TextStyle(color: colors.textColor),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text(
                'I Understand',
                style: TextStyle(
                  color: colors.textColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: () async {
                await _saveUserAgreement();
                Navigator.of(context).pop();
                _showGalleryOptions();
              },
            ),
          ],
        );
      },
    );
  }

  // ── FIX: use _resolvedUid instead of FirebaseAuth ──
  void _loadUserData() async {
    setState(() => _isLoading = true);
    try {
      final uid = _resolvedUid;
      if (uid == null || uid.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User not authenticated')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      final userData =
          await _supabase.from('users').select().eq('uid', uid).single();

      setState(() {
        _bioController.text = userData['bio'] ?? '';
        _initialPhotoUrl = userData['photoUrl'];
        _currentPhotoUrl = _initialPhotoUrl ?? 'default';
        _username = userData['username'] ?? 'User';
        _countryCode = userData['country']?.toString();
        _isVerified = userData['isVerified'] == true;
      });

      // Initialize profile video if current photo is a video
      if (_currentPhotoUrl != null &&
          _currentPhotoUrl != 'default' &&
          _isVideoUrl(_currentPhotoUrl)) {
        _initializeProfileVideo(_currentPhotoUrl!);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading profile: $e')),
        );
      }
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  // Initialize video player for profile video
  Future<void> _initializeProfileVideo(String videoUrl) async {
    if (_profileVideoController != null) {
      await _profileVideoController!.dispose();
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();

      if (mounted) {
        setState(() {
          _profileVideoController = controller;
          _isProfileVideoInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProfileVideoInitialized = false;
        });
      }
    }
  }

  // Build video player widget for profile video
  Widget _buildProfileVideoPlayer(_EditProfileColorSet colors) {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.cardColor,
        ),
        child: Center(
          child: CircularProgressIndicator(
            color: colors.progressIndicatorColor,
          ),
        ),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: 100,
        height: 100,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _profileVideoController!.value.size.width,
            height: _profileVideoController!.value.size.height,
            child: VideoPlayer(_profileVideoController!),
          ),
        ),
      ),
    );
  }

  // Show only 2 options - Choose from Gallery and Remove
  void _showEditOptions(_EditProfileColorSet colors) {
    final bool hasAnyPhoto =
        _currentPhotoUrl != null && _currentPhotoUrl != 'default';

    showModalBottomSheet(
      context: context,
      backgroundColor: colors.cardColor,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.photo_library, color: colors.iconColor),
                title: Text('Choose from Gallery',
                    style: TextStyle(color: colors.textColor)),
                onTap: () {
                  Navigator.pop(context);
                  _showWarningDialog();
                },
              ),
              if (hasAnyPhoto)
                ListTile(
                  leading: Icon(Icons.delete, color: colors.iconColor),
                  title: Text(
                    'Remove',
                    style: TextStyle(color: colors.textColor),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _removePhoto();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // Show gallery options similar to Add Post flow
  Future<void> _showGalleryOptions() async {
    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          backgroundColor: colors.cardColor,
          title: Text(
            'Choose Media Type',
            style: TextStyle(color: colors.textColor),
          ),
          children: <Widget>[
            SimpleDialogOption(
              padding: const EdgeInsets.all(20),
              child: Text('Choose Image from Gallery',
                  style: TextStyle(color: colors.textColor)),
              onPressed: () async {
                Navigator.pop(context);
                await _pickImage(ImageSource.gallery);
              },
            ),
            SimpleDialogOption(
              padding: const EdgeInsets.all(20),
              child: Text('Choose Video from Gallery',
                  style: TextStyle(color: colors.textColor)),
              onPressed: () async {
                Navigator.pop(context);
                await _pickVideo(ImageSource.gallery);
              },
            ),
            SimpleDialogOption(
              padding: const EdgeInsets.all(20),
              child: Text("Cancel", style: TextStyle(color: colors.textColor)),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      setState(() {
        _isVideo = false;
        _isLoading = true;
        _isTrimming = false;
        _videoFile = null;
        _shouldRemoveCurrentMedia = false;
        if (_profileVideoController != null) {
          _profileVideoController!.dispose();
          _profileVideoController = null;
          _isProfileVideoInitialized = false;
        }
      });

      final pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final Uint8List imageBytes = await pickedFile.readAsBytes();
        setState(() {
          _image = imageBytes;
          _videoFile = null;
          _pickedFileName = pickedFile.name;
          _currentPhotoUrl = null;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

  Future<void> _pickVideo(ImageSource source) async {
    try {
      setState(() {
        _isVideo = true;
        _isLoading = true;
        _image = null;
        _shouldRemoveCurrentMedia = false;
        if (_profileVideoController != null) {
          _profileVideoController!.dispose();
          _profileVideoController = null;
          _isProfileVideoInitialized = false;
        }
      });

      final pickedFile = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );

      if (pickedFile != null) {
        final File videoFile = File(pickedFile.path);

        _videoFile = videoFile;
        _loadVideo();

        setState(() {
          _image = null;
          _pickedFileName = pickedFile.name;
          _currentPhotoUrl = null;
          _isTrimming = true;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick video: $e')),
        );
      }
    }
  }

  void _loadVideo() {
    if (_videoFile != null) {
      _trimmer.loadVideo(videoFile: _videoFile!);
    }
  }

  Future<String?> _trimVideo() async {
    setState(() {
      _progressVisibility = true;
    });

    String? trimmedPath;

    await _trimmer.saveTrimmedVideo(
      startValue: _startValue,
      endValue: _endValue,
      onSave: (String? value) {
        setState(() {
          _progressVisibility = false;
          trimmedPath = value;
        });
      },
    );

    return trimmedPath;
  }

  Future<void> _deleteOldMedia(String mediaUrl) async {
    try {
      if (mediaUrl.contains('supabase.co/storage')) {
        if (_isVideoUrl(mediaUrl)) {
          final uri = Uri.parse(mediaUrl);
          final pathSegments = uri.pathSegments;
          final videosIndex = pathSegments.indexOf('videos');
          if (videosIndex != -1 && videosIndex < pathSegments.length - 1) {
            final filePath = pathSegments.sublist(videosIndex + 1).join('/');
            await StorageMethods().deleteVideoFromSupabase('videos', filePath);
          }
        } else {
          await StorageMethods().deleteImage(mediaUrl);
        }
      }
    } catch (e) {
      print('Error deleting old media: $e');
    }
  }

  void _removePhoto() {
    final bool isVideo = _currentPhotoUrl != null &&
        _currentPhotoUrl != 'default' &&
        _isVideoUrl(_currentPhotoUrl!);

    final mediaType = isVideo ? 'video' : 'picture';

    setState(() {
      _image = null;
      _videoFile = null;
      _isVideo = false;
      _pickedFileName = null;
      _currentPhotoUrl = 'default';
      _isTrimming = false;
      _shouldRemoveCurrentMedia = true;

      if (_profileVideoController != null) {
        _profileVideoController!.dispose();
        _profileVideoController = null;
        _isProfileVideoInitialized = false;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Profile $mediaType removed. Save to update.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── FIX: use _resolvedUid instead of FirebaseAuth ──
  Future<void> _saveProfile() async {
    final uid = _resolvedUid;
    if (uid == null || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not authenticated')),
      );
      return;
    }

    if (_bioController.text.length > 250) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Bio cannot exceed 250 characters. Your bio is ${_bioController.text.length} characters.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return WillPopScope(
          onWillPop: () async => false,
          child: Dialog(
            backgroundColor: colors.dialogBackgroundColor,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: colors.progressIndicatorColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Saving profile...',
                    style: TextStyle(
                      color: colors.dialogTextColor,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      Map<String, dynamic> updatedData = {
        'bio': _bioController.text,
      };

      String? oldMediaToDelete;

      if (_shouldRemoveCurrentMedia &&
          _initialPhotoUrl != null &&
          _initialPhotoUrl != 'default') {
        oldMediaToDelete = _initialPhotoUrl;
      }

      if (_image != null) {
        String fileName = _pickedFileName ??
            'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
        String photoUrl = await StorageMethods().uploadImageToSupabase(
          _image!,
          fileName,
          useUserFolder: true,
        );
        updatedData['photoUrl'] = photoUrl;

        if (_initialPhotoUrl != null &&
            _initialPhotoUrl != 'default' &&
            _initialPhotoUrl!.contains('supabase.co/storage')) {
          oldMediaToDelete = _initialPhotoUrl;
        }
      } else if (_videoFile != null) {
        if (_isTrimming) {
          setState(() => _progressVisibility = true);
          final String? trimmedPath = await _trimVideo();
          setState(() => _progressVisibility = false);

          if (trimmedPath == null) {
            if (mounted) Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to trim video')),
            );
            setState(() => _isLoading = false);
            return;
          }

          _videoFile = File(trimmedPath);
        }

        String fileName = _pickedFileName ??
            'profile_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

        Uint8List videoBytes = await _videoFile!.readAsBytes();

        String videoUrl = await StorageMethods().uploadVideoToSupabase(
          videoBytes,
          fileName,
          useUserFolder: true,
        );
        updatedData['photoUrl'] = videoUrl;

        if (_initialPhotoUrl != null &&
            _initialPhotoUrl != 'default' &&
            _initialPhotoUrl!.contains('supabase.co/storage')) {
          oldMediaToDelete = _initialPhotoUrl;
        }
      } else if (_shouldRemoveCurrentMedia) {
        updatedData['photoUrl'] = 'default';
      }

      await FirebaseSupabaseService.update(
        'users',
        updates: updatedData,
        filters: {'uid': uid},
      );

      if (oldMediaToDelete != null &&
          oldMediaToDelete.contains('supabase.co/storage')) {
        _deleteOldMediaInBackground(oldMediaToDelete);
      }

      if (mounted) {
        Navigator.of(context).pop();

        setState(() {
          if (updatedData.containsKey('photoUrl')) {
            _initialPhotoUrl = updatedData['photoUrl'];
          }
          _currentPhotoUrl = _initialPhotoUrl;
          _image = null;
          _videoFile = null;
          _isTrimming = false;
          _pickedFileName = null;
          _shouldRemoveCurrentMedia = false;
        });

        if (updatedData.containsKey('photoUrl') &&
            updatedData['photoUrl'] != 'default' &&
            _isVideoUrl(updatedData['photoUrl'])) {
          await _initializeProfileVideo(updatedData['photoUrl']);
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully!')),
        );

        Navigator.pop(context, {
          'bio': _bioController.text,
          'photoUrl': updatedData['photoUrl'] ?? _initialPhotoUrl,
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update profile: $e')),
        );
      }
    }
    setState(() => _isLoading = false);
  }

  void _deleteOldMediaInBackground(String mediaUrl) {
    Future.delayed(Duration.zero, () async {
      try {
        await _deleteOldMedia(mediaUrl);
      } catch (e) {
        print('Failed to delete old media in background: $e');
      }
    });
  }

  Widget _buildVideoTrimmer() {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.iconColor),
        backgroundColor: colors.backgroundColor,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.iconColor),
          onPressed: () {
            setState(() {
              _isTrimming = false;
              _videoFile = null;
            });
          },
        ),
        title: Text('Trim Video', style: TextStyle(color: colors.textColor)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(bottom: 16.0),
              color: Colors.black,
              child: Column(
                children: <Widget>[
                  if (_progressVisibility || _isLoading)
                    LinearProgressIndicator(
                      color: colors.progressIndicatorColor,
                      backgroundColor:
                          colors.progressIndicatorColor.withOpacity(0.2),
                    ),
                  Expanded(
                    child: VideoViewer(trimmer: _trimmer),
                  ),
                  Center(
                    child: TrimViewer(
                      trimmer: _trimmer,
                      viewerHeight: 50.0,
                      viewerWidth: MediaQuery.of(context).size.width,
                      maxVideoLength: const Duration(seconds: 5),
                      onChangeStart: (value) => _startValue = value,
                      onChangeEnd: (value) => _endValue = value,
                      onChangePlaybackState: (value) =>
                          setState(() => _isPlaying = value),
                    ),
                  ),
                  TextButton(
                    child: _isPlaying
                        ? const Icon(Icons.pause,
                            size: 80.0, color: Colors.white)
                        : const Icon(Icons.play_arrow,
                            size: 80.0, color: Colors.white),
                    onPressed: () async {
                      bool playbackState = await _trimmer.videoPlaybackControl(
                        startValue: _startValue,
                        endValue: _endValue,
                      );
                      setState(() {
                        _isPlaying = playbackState;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: ElevatedButton(
                      onPressed: () => _saveProfile(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.buttonBackgroundColor,
                        foregroundColor: colors.buttonTextColor,
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileImage(_EditProfileColorSet colors) {
    if (_image != null) {
      return ClipOval(
        child: Image.memory(
          _image!,
          width: 100,
          height: 100,
          fit: BoxFit.cover,
        ),
      );
    }

    if (_videoFile != null && !_isTrimming) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.cardColor,
        ),
        child: Center(
          child: Icon(Icons.videocam, size: 40, color: colors.iconColor),
        ),
      );
    }

    if (_currentPhotoUrl != null && _currentPhotoUrl != 'default') {
      if (_isVideoUrl(_currentPhotoUrl)) {
        return _buildProfileVideoPlayer(colors);
      } else {
        return ClipOval(
          child: Image.network(
            _currentPhotoUrl!,
            width: 100,
            height: 100,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildDefaultAvatar(colors),
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.cardColor,
                ),
                child: Center(
                  child: CircularProgressIndicator(
                    color: colors.progressIndicatorColor,
                  ),
                ),
              );
            },
          ),
        );
      }
    }

    return _buildDefaultAvatar(colors);
  }

  @override
  Widget build(BuildContext context) {
    if (_isTrimming) {
      return _buildVideoTrimmer();
    }

    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final uid = _resolvedUid;

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.iconColor),
        title: Text(
          'Edit Profile',
          style: TextStyle(color: colors.textColor),
        ),
        centerTitle: true,
        backgroundColor: colors.backgroundColor,
        elevation: 0,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor))
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (uid != null && _username != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20.0),
                      child: VerifiedUsernameWidget(
                        username: _username!,
                        uid: uid,
                        countryCode: _countryCode,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: colors.textColor,
                        ),
                      ),
                    ),
                  Center(
                    child: GestureDetector(
                      onTap: () => _showEditOptions(colors),
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: colors.cardColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.borderColor,
                            width: 2.0,
                          ),
                        ),
                        child: Stack(
                          children: [
                            ClipOval(
                              child: _buildProfileImage(colors),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: colors.cardColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colors.backgroundColor,
                                    width: 2,
                                  ),
                                ),
                                child: Icon(
                                  Icons.edit,
                                  size: 14,
                                  color: colors.iconColor,
                                ),
                              ),
                            ),
                            if (_currentPhotoUrl != null &&
                                _currentPhotoUrl != 'default' &&
                                _isVideoUrl(_currentPhotoUrl))
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.videocam,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _bioController,
                    decoration: InputDecoration(
                      labelText: 'Bio',
                      labelStyle: TextStyle(color: colors.textColor),
                      hintText: 'Write something about yourself...',
                      hintStyle: TextStyle(color: colors.hintTextColor),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.borderColor),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.borderColor),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.borderColor),
                      ),
                      filled: true,
                      fillColor: colors.cardColor,
                    ),
                    style: TextStyle(color: colors.textColor),
                    maxLines: 3,
                    maxLength: 250,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _saveProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.buttonBackgroundColor,
                      foregroundColor: colors.buttonTextColor,
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
    );
  }
}

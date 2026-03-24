// lib/screens/Profile_page/video_edit_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_trimmer/video_trimmer.dart';
import 'package:Ratedly/screens/Profile_page/add_post_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';

// Trim is the first tool so it is selected by default on open.
enum _Tool { trim, filters, adjust, draw, text, rotate }

class VideoEditScreen extends StatefulWidget {
  final File videoFile;
  final VoidCallback? onPostUploaded;

  const VideoEditScreen({
    Key? key,
    required this.videoFile,
    this.onPostUploaded,
  }) : super(key: key);

  @override
  State<VideoEditScreen> createState() => _VideoEditScreenState();
}

class _VideoEditScreenState extends State<VideoEditScreen> {
  // ── Preview player ─────────────────────────────────────────────────────────
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isPlaying          = false;

  // ── Active video file ──────────────────────────────────────────────────────
  // Starts as the original file. Replaced with the trimmed file when the user
  // presses Save in the Trim panel — so all other tools and the final post use
  // the trimmed version, not the original.
  late File _activeVideoFile;

  // ── Trimmer ────────────────────────────────────────────────────────────────
  final Trimmer _trimmer       = Trimmer();
  double _startValue           = 0.0;
  double _endValue             = 0.0;
  bool   _isTrimPlaying        = false;
  bool   _isSavingTrim         = false;   // Next button spinner
  bool   _isSavingTrimInline   = false;   // Save button spinner inside trim panel
  bool   _trimDirty            = false;
  bool   _trimApplied          = false;

  // ── Active tool ────────────────────────────────────────────────────────────
  // Defaults to trim so the user lands on the trimmer view.
  _Tool _activeTool = _Tool.trim;

  // ── Filter / Adjust ────────────────────────────────────────────────────────
  int             _selectedFilterIndex = 0;
  EditAdjustments _adj = const EditAdjustments();

  // ── Draw ───────────────────────────────────────────────────────────────────
  final List<DrawStroke> _strokes = [];
  DrawStroke? _currentStroke;
  DrawTool _drawTool  = DrawTool.brush;
  Color    _drawColor = Colors.white;
  double   _drawSize  = 8.0;
  bool     _isDrawing = false;

  // ── Text overlays ──────────────────────────────────────────────────────────
  bool _isTyping = false;
  final List<TextOverlay> _overlays = [];
  int? _selectedOverlayIndex;
  final TextEditingController _textCtrl  = TextEditingController();
  final FocusNode             _textFocus = FocusNode();
  Color  _tColor = Colors.white;
  double _tSize  = 32.0;
  bool   _tBold  = true;
  int    _tFont  = 0;

  // ── Rotation ───────────────────────────────────────────────────────────────
  int _rotationQuarters = 0;

  // ── Drag-to-trash ──────────────────────────────────────────────────────────
  bool _isDragging  = false;
  int? _dragIndex;
  bool _isOverTrash = false;

  // ── Layout ─────────────────────────────────────────────────────────────────
  static const double _topBarH  = 56.0;
  static const double _panelH   = 212.0;

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _activeVideoFile = widget.videoFile;
    WidgetsBinding.instance.addPostFrameCallback((_) => _logBoot());
    _initPreviewPlayer();
    _trimmer.loadVideo(videoFile: widget.videoFile);
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _trimmer.dispose();
    _textCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _logBoot() async {
    try {
      final sz = MediaQuery.of(context).size;
      final tp = MediaQuery.of(context).padding.top;
      final bp = MediaQuery.of(context).padding.bottom;
      final videoH = sz.height - tp - _topBarH - _panelH - bp;
      final fileExists = widget.videoFile.existsSync();
      await Supabase.instance.client.from('posts_errors').insert({
        'operation_type':  'video_edit/boot',
        'additional_data': {
          'screenW': sz.width, 'screenH': sz.height,
          'topPad': tp, 'botPad': bp,
          'computedVideoH': videoH, 'videoHNegative': videoH <= 0,
          'filePath': widget.videoFile.path,
          'fileExists': fileExists,
          'fileSizeBytes': fileExists ? widget.videoFile.lengthSync() : 0,
        },
      });
    } catch (_) {}
  }

  Future<void> _initPreviewPlayer() async {
    await _log(operation: 'video_edit/player_init_start', data: {
      'filePath': widget.videoFile.path,
      'fileExists': widget.videoFile.existsSync(),
    });
    try {
      final c = VideoPlayerController.file(
        widget.videoFile,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await c.initialize();
      await c.setLooping(true);
      await _log(operation: 'video_edit/player_init_success', data: {
        'width': c.value.size.width, 'height': c.value.size.height,
        'duration_ms': c.value.duration.inMilliseconds,
        'aspectRatio': c.value.aspectRatio,
      });
      if (mounted) {
        setState(() {
          _videoController    = c;
          _isVideoInitialized = true;
          _isPlaying          = false;
        });
      }
    } catch (e, st) {
      await _log(
        operation: 'video_edit/player_init_error',
        errorMessage: e.toString(), stackTrace: st.toString(),
        data: { 'filePath': widget.videoFile.path },
      );
    }
  }

  // ===========================================================================
  // TOOL SELECTION
  // ===========================================================================

  /// Reloads the trimmer on the current active file so the VideoViewer
  /// re-acquires its platform texture after having been hidden.
  /// The previously stored [_startValue] / [_endValue] are NOT touched —
  /// they remain valid for [saveTrimmedVideo] even though the TrimViewer
  /// handle visuals reset to full-range.
  void _reloadTrimmer() {
    _trimmer.loadVideo(videoFile: _activeVideoFile);
    // Reset trim-playing state since the trimmer re-initialises paused.
    if (mounted) setState(() => _isTrimPlaying = false);
  }

  Future<void> _onToolTap(_Tool tool) async {
    if (tool == _Tool.text)  { _enterTextMode(); return; }
    if (tool == _Tool.rotate) {
      setState(() => _rotationQuarters = (_rotationQuarters + 1) % 4);
      return;
    }

    final wasTrim   = _activeTool == _Tool.trim;
    final goingTrim = tool == _Tool.trim;

    if (goingTrim && !wasTrim) {
      // ── Returning to Trim ──────────────────────────────────────────────
      // 1. Stop the preview player so its texture doesn't compete with the
      //    trimmer's internal VideoPlayerController.
      await _videoController?.pause();
      if (mounted) setState(() => _isPlaying = false);

      // 2. Reload the trimmer so VideoViewer re-acquires its platform
      //    texture — this is what fixes the blank-screen bug.
      _reloadTrimmer();
    }

    if (!goingTrim && wasTrim) {
      // ── Leaving Trim ───────────────────────────────────────────────────
      // 1. Pause the trimmer's own playback before hiding it, so both
      //    VideoPlayerControllers are not active simultaneously (which is
      //    what causes the texture conflict in the first place).
      if (_isTrimPlaying) {
        try {
          await _trimmer.videoPlaybackControl(
            startValue: _startValue,
            endValue: _endValue,
          );
        } catch (_) {}
        if (mounted) setState(() => _isTrimPlaying = false);
      }

      // 2. Start the preview player.
      await _videoController?.play();
      if (mounted) setState(() => _isPlaying = _videoController?.value.isPlaying ?? false);
    }

    // Toggle off if already active (except trim — always show trim panel).
    setState(() {
      _activeTool = (tool == _activeTool && tool != _Tool.trim) ? _Tool.trim : tool;
      _isDrawing  = false;
    });
  }

  // ===========================================================================
  // PLAY / PAUSE  (preview player)
  // ===========================================================================

  Future<void> _togglePlayPause() async {
    if (_videoController == null || !_isVideoInitialized) return;
    if (_isPlaying) {
      await _videoController!.pause();
    } else {
      await _videoController!.play();
    }
    if (mounted) setState(() => _isPlaying = _videoController!.value.isPlaying);
  }

  // ===========================================================================
  // SILENCE & STOP
  // ===========================================================================

  Future<void> _silenceAndStop() async {
    await _videoController?.pause();
    if (mounted) setState(() => _isPlaying = false);
  }

  // ===========================================================================
  // SAVE TRIM
  // Re-encodes the trimmed segment, swaps _activeVideoFile, and re-initialises
  // the preview player so every other tool immediately sees the shorter clip.
  // ===========================================================================

  Future<void> _saveTrim() async {
    if (!_trimDirty) return; // nothing changed, nothing to do
    if (mounted) setState(() => _isSavingTrimInline = true);

    await _log(operation: 'trim/save_start', data: {
      'startValue': _startValue, 'endValue': _endValue,
      'activeFilePath': _activeVideoFile.path,
    });

    File? trimmedFile;
    try {
      final completer = Completer<String?>();
      await _trimmer.saveTrimmedVideo(
        startValue: _startValue,
        endValue:   _endValue,
        onSave: (String? path) {
          if (!completer.isCompleted) completer.complete(path);
        },
      );
      final savedPath = await completer.future
          .timeout(const Duration(seconds: 30), onTimeout: () => null);

      if (savedPath != null) {
        final f       = File(savedPath);
        final exists  = f.existsSync();
        final bytes   = exists ? f.lengthSync() : 0;
        await _log(operation: 'trim/saved_inline', data: {
          'savedPath': savedPath, 'exists': exists, 'sizeBytes': bytes,
        });
        if (exists && bytes > 0) trimmedFile = f;
      }
    } catch (e, st) {
      await _log(
        operation: 'trim/save_inline_error',
        errorMessage: e.toString(), stackTrace: st.toString(),
      );
    }

    if (!mounted) return;

    if (trimmedFile != null) {
      // Swap the active file reference.
      setState(() => _activeVideoFile = trimmedFile!);

      // Dispose old controller and spin up a new one pointing to trimmed file.
      final old = _videoController;
      setState(() { _isVideoInitialized = false; _isPlaying = false; });
      old?.dispose();

      try {
        final c = VideoPlayerController.file(
          trimmedFile,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
        await c.initialize();
        await c.setLooping(true);
        if (mounted) {
          setState(() {
            _videoController    = c;
            _isVideoInitialized = true;
            _isPlaying          = false;
            // Reset trim state — the trimmed file is now the baseline.
            _trimDirty   = false;
            _trimApplied = true;
            _startValue  = 0.0;
            _endValue    = 0.0;
            // Trim tab is now hidden — move to filters so the panel isn't blank.
            _activeTool  = _Tool.filters;
          });
          // Reload the trimmer on the new (shorter) file so the scrubber
          // reflects the trimmed duration.
          _trimmer.loadVideo(videoFile: trimmedFile);
          // Start playback so the trimmed clip is immediately visible in preview.
          c.play();
          if (mounted) setState(() => _isPlaying = true);
        }
      } catch (e, st) {
        await _log(
          operation: 'trim/reinit_error',
          errorMessage: e.toString(), stackTrace: st.toString(),
        );
      }
    }

    if (mounted) setState(() => _isSavingTrimInline = false);
  }

  // ===========================================================================
  // DRAW
  // ===========================================================================

  void _onDrawStart(DragStartDetails d) {
    setState(() {
      _isDrawing     = true;
      _currentStroke = DrawStroke(
        points: [d.localPosition], color: _drawColor,
        strokeWidth: _drawSize,   tool: _drawTool,
      );
    });
  }

  void _onDrawUpdate(DragUpdateDetails d) {
    if (!_isDrawing || _currentStroke == null) return;
    setState(() {
      _currentStroke = DrawStroke(
        points: [..._currentStroke!.points, d.localPosition],
        color: _currentStroke!.color,
        strokeWidth: _currentStroke!.strokeWidth,
        tool: _currentStroke!.tool,
      );
    });
  }

  void _onDrawEnd(DragEndDetails _) {
    if (_currentStroke != null) {
      setState(() {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
        _isDrawing     = false;
      });
    }
  }

  // ===========================================================================
  // TEXT
  // ===========================================================================

  void _enterTextMode() {
    _textCtrl.clear();
    setState(() {
      _isTyping = true;
      _tColor = Colors.white; _tSize = 32.0; _tBold = true; _tFont = 0;
    });
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _confirmText() {
    final text = _textCtrl.text.trim();
    if (text.isNotEmpty) {
      setState(() => _overlays.add(TextOverlay(
        text: text, position: const Offset(0.5, 0.45),
        color: _tColor, fontSize: _tSize, isBold: _tBold, fontIndex: _tFont,
      )));
    }
    _textCtrl.clear(); _textFocus.unfocus();
    setState(() => _isTyping = false);
  }

  void _cancelText() {
    _textCtrl.clear(); _textFocus.unfocus();
    setState(() => _isTyping = false);
  }

  // ===========================================================================
  // DRAG-TO-TRASH
  // ===========================================================================

  bool _overTrash(Offset pos, double h) => pos.dy * h >= h - kTrashZoneH;

  void _onTextDragStart(int i) => setState(() {
    _isDragging = true; _dragIndex = i; _selectedOverlayIndex = i; _isOverTrash = false;
  });

  void _onTextDragUpdate(int i, DragUpdateDetails d, double w, double h) {
    final o = _overlays[i];
    final p = Offset(
      (o.position.dx + d.delta.dx / w).clamp(0.0, 0.9),
      (o.position.dy + d.delta.dy / h).clamp(0.0, 0.99),
    );
    setState(() { _overlays[i] = o.copyWith(position: p); _isOverTrash = _overTrash(p, h); });
  }

  void _onTextDragEnd(int i, double h) {
    final del = _overTrash(_overlays[i].position, h);
    setState(() {
      _isDragging = false; _dragIndex = null; _isOverTrash = false;
      if (del) { _overlays.removeAt(i); _selectedOverlayIndex = null; }
    });
  }

  // ===========================================================================
  // LOGGING
  // ===========================================================================

  Future<void> _log({
    required String operation,
    String? errorMessage,
    String? stackTrace,
    Map<String, dynamic>? data,
  }) async {
    try {
      await Supabase.instance.client.from('posts_errors').insert({
        'operation_type':  operation,
        'error_message':   errorMessage,
        'stack_trace':     stackTrace,
        'additional_data': data,
      });
    } catch (_) {}
  }

  // ===========================================================================
  // NEXT
  // ===========================================================================

  Future<void> _onNext() async {
    // If the user moved trim handles but never pressed Save, encode now as a
    // fallback so they never accidentally post the full original.
    if (_trimDirty) {
      await _saveTrim();
      if (!mounted) return;
    }

    await _silenceAndStop();
    if (!mounted) return;

    await _log(operation: 'trim/navigate', data: {
      'activeFilePath':   _activeVideoFile.path,
      'activeFileExists': _activeVideoFile.existsSync(),
      'activeFileSizeBytes': _activeVideoFile.existsSync()
          ? _activeVideoFile.lengthSync() : null,
      'trimApplied': _trimApplied,
    });

    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => AddPostScreen(
      initialVideoFile: _activeVideoFile,
      onPostUploaded:   widget.onPostUploaded,
    )));
  }

  List<double> get _currentMatrix =>
      _adj.combinedMatrix(kFilters[_selectedFilterIndex].matrix);

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    try {
      return _buildBody(context);
    } catch (e, st) {
      unawaited(_log(
        operation: 'video_edit/build_exception',
        errorMessage: e.toString(), stackTrace: st.toString(),
      ));
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text('Something went wrong.\n${e.toString()}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
            textAlign: TextAlign.center)),
      );
    }
  }

  Widget _buildBody(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final topPad     = MediaQuery.of(context).padding.top;
    final botPad     = MediaQuery.of(context).padding.bottom;

    final videoH = (screenSize.height - topPad - _topBarH - _panelH - botPad)
        .clamp(120.0, double.infinity);

    final isTrim       = _activeTool == _Tool.trim;
    final isDrawActive = _activeTool == _Tool.draw;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: Stack(children: [
        Column(children: [
          SizedBox(height: topPad),

          // ── Top bar ──────────────────────────────────────────────────────
          _buildTopBar(),

          // ── Video area ───────────────────────────────────────────────────
          SizedBox(
            height: videoH,
            child: Stack(children: [

              // IndexedStack keeps both players in the render tree at all times
              // so the Trimmer's native texture never loses its surface binding.
              // Index 0 = VideoViewer (Trim tool), Index 1 = preview player.
              Positioned.fill(
                child: IndexedStack(
                  index: isTrim ? 0 : 1,
                  children: [
                    // 0 — Trimmer's VideoViewer
                    Container(
                      color: Colors.black,
                      child: VideoViewer(trimmer: _trimmer),
                    ),

                    // 1 — Filtered + rotated preview player
                    SizedBox.expand(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: isDrawActive ? null : () {
                          setState(() => _selectedOverlayIndex = null);
                          _togglePlayPause();
                        },
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix(_currentMatrix),
                          child: Transform.rotate(
                            angle: _rotationQuarters * 3.14159265 / 2,
                            child: _isVideoInitialized && _videoController != null
                                ? Center(
                                    child: AspectRatio(
                                      aspectRatio: _videoController!.value.aspectRatio,
                                      child: VideoPlayer(_videoController!),
                                    ),
                                  )
                                : const Center(
                                    child: CircularProgressIndicator(color: Colors.white)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Draw strokes (only on preview) — always rendered, never blocks events
              if (!isTrim)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: DrawingPainter(strokes: _strokes, currentStroke: _currentStroke),
                    ),
                  ),
                ),

              // Dedicated draw gesture overlay — sits on top of everything so the
              // VideoPlayer texture cannot intercept touch events.
              if (!isTrim && isDrawActive)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart:  _onDrawStart,
                    onPanUpdate: _onDrawUpdate,
                    onPanEnd:    _onDrawEnd,
                    child: const SizedBox.expand(),
                  ),
                ),

              // Text overlays (only on preview)
              if (!isTrim)
                ..._buildTextOverlays(screenSize.width, videoH),

              // Play/pause icon (preview only, not draw)
              if (!isTrim && !isDrawActive && !_isPlaying)
                const Center(child: Icon(Icons.play_circle_outline, color: Colors.white54, size: 64)),

              // Draw cursor hint
              if (isDrawActive)
                Positioned(
                  bottom: 12, left: 0, right: 0,
                  child: Center(child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width:  _drawSize.clamp(6, 24),
                        height: _drawSize.clamp(6, 24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, color: _drawColor,
                          border: Border.all(color: Colors.white.withOpacity(0.5), width: 1),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_drawTool.label,
                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12)),
                    ]),
                  )),
                ),

              // Trash zone
              if (_isDragging)
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: TrashZone(isOverTrash: _isOverTrash),
                ),
            ]),
          ),

          // ── Single panel ─────────────────────────────────────────────────
          Container(
            height: _panelH,
            color: Colors.black,
            child: _buildPanel(),
          ),

          SizedBox(height: botPad),
        ]),

        // ── Text entry overlay ────────────────────────────────────────────
        if (_isTyping)
          Positioned.fill(
            child: TextEntryOverlay(
              controller: _textCtrl, focusNode: _textFocus,
              textColor: _tColor, fontSize: _tSize, isBold: _tBold, fontIndex: _tFont,
              onColorChanged: (c) => setState(() => _tColor = c),
              onSizeChanged:  (v) => setState(() => _tSize  = v),
              onBoldToggle:   ()  => setState(() => _tBold  = !_tBold),
              onFontChanged:  (i) => setState(() => _tFont  = i),
              onConfirm: _confirmText, onCancel: _cancelText,
              topPadding: topPad,
            ),
          ),
      ]),
    );
  }

  // ===========================================================================
  // TOP BAR
  // ===========================================================================

  Widget _buildTopBar() => SizedBox(
    height: _topBarH,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () async {
              await _silenceAndStop();
              if (mounted) Navigator.pop(context);
            },
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
            ),
          ),
          const Text('Edit Video',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
          GestureDetector(
            onTap: _isSavingTrim ? null : _onNext,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: _isSavingTrim
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  : const Text('Next',
                      style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    ),
  );

  // ===========================================================================
  // SINGLE PANEL
  // ===========================================================================

  Widget _buildPanel() {
    return Column(children: [
      // ── Tool icon row ─────────────────────────────────────────────────────
      SizedBox(
        height: 86,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          children: _Tool.values.where((t) => !(t == _Tool.trim && _trimApplied)).map((tool) {
            final isActive = _activeTool == tool;
            final showBadge = tool == _Tool.trim && _trimApplied && !isActive;

            return GestureDetector(
              onTap: () => _onToolTap(tool),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 7),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Stack(clipBehavior: Clip.none, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 50, height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive
                            ? Colors.white.withOpacity(0.18)
                            : Colors.white.withOpacity(0.07),
                        border: Border.all(
                          color: isActive
                              ? Colors.white
                              : Colors.white.withOpacity(0.16),
                          width: isActive ? 1.5 : 1.0,
                        ),
                      ),
                      child: Icon(_toolIcon(tool),
                          color: isActive
                              ? Colors.white
                              : Colors.white.withOpacity(0.6),
                          size: 22),
                    ),
                    if (showBadge)
                      Positioned(
                        top: 2, right: 2,
                        child: Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle, color: Colors.white,
                            border: Border.all(color: Colors.black.withOpacity(0.4), width: 1),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 5),
                  Text(_toolLabel(tool),
                      style: TextStyle(
                        color: isActive ? Colors.white : Colors.white.withOpacity(0.48),
                        fontSize: 10,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                      )),
                ]),
              ),
            );
          }).toList(),
        ),
      ),

      // Divider
      Divider(color: Colors.white.withOpacity(0.07), height: 1),

      // ── Detail area for selected tool ─────────────────────────────────────
      Expanded(child: _buildToolDetail()),
    ]);
  }

  Widget _buildToolDetail() {
    switch (_activeTool) {
      // ── Trim + Audio ──────────────────────────────────────────────────────
      case _Tool.trim:
        return _buildTrimDetail();

      case _Tool.filters:
        return FilterStrip(
          selectedIndex: _selectedFilterIndex, previewImage: null,
          onSelect: (i) => setState(() => _selectedFilterIndex = i),
        );
      case _Tool.adjust:
        return AdjustPanel(
          adjustments: _adj,
          onChanged:   (a) => setState(() => _adj = a),
        );
      case _Tool.draw:
        return DrawPanel(
          tool: _drawTool, color: _drawColor, strokeWidth: _drawSize,
          onUndo:         () => setState(() { if (_strokes.isNotEmpty) _strokes.removeLast(); }),
          onClear:        () => setState(() => _strokes.clear()),
          onToolChanged:  (t) => setState(() => _drawTool  = t),
          onColorChanged: (c) => setState(() => _drawColor = c),
          onSizeChanged:  (v) => setState(() => _drawSize  = v),
        );
      default:
        return Center(
          child: Text('Select a tool above',
              style: TextStyle(color: Colors.white.withOpacity(0.22), fontSize: 13)),
        );
    }
  }

  // ── Trim + Audio detail ───────────────────────────────────────────────────

  Widget _buildTrimDetail() {
    return SingleChildScrollView(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 8, right: 8),
          child: TrimViewer(
            trimmer:        _trimmer,
            viewerHeight:   70,
            viewerWidth:    MediaQuery.of(context).size.width - 16,
            maxVideoLength: const Duration(seconds: 60),
            editorProperties: TrimEditorProperties(
              circleSize:       12,
              borderWidth:       4,
              scrubberWidth:     2,
              sideTapSize:      24,
              circlePaintColor:  Colors.white,
              borderPaintColor:  Colors.white,
              scrubberPaintColor: Colors.white,
            ),
            onChangeStart: (v) { _startValue = v; _trimDirty = true; },
            onChangeEnd:   (v) { _endValue   = v; _trimDirty = true; },
            onChangePlaybackState: (p) {
              if (mounted) setState(() => _isTrimPlaying = p);
            },
          ),
        ),

        // Play/pause + Save row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () async {
                  try {
                    final p = await _trimmer.videoPlaybackControl(
                      startValue: _startValue, endValue: _endValue,
                    );
                    if (mounted) setState(() => _isTrimPlaying = p);
                  } catch (_) {}
                },
                child: Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.1),
                    border: Border.all(color: Colors.white.withOpacity(0.28), width: 1),
                  ),
                  child: Icon(
                    _isTrimPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white, size: 15,
                  ),
                ),
              ),

              GestureDetector(
                onTap: (_trimDirty && !_isSavingTrimInline) ? _saveTrim : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  decoration: BoxDecoration(
                    color: _trimDirty
                        ? Colors.white
                        : Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: _isSavingTrimInline
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : Text(
                          'Save',
                          style: TextStyle(
                            color: _trimDirty
                                ? Colors.black
                                : Colors.white.withOpacity(0.3),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ===========================================================================
  // TEXT OVERLAYS
  // ===========================================================================

  List<Widget> _buildTextOverlays(double w, double h) {
    return _overlays.asMap().entries.map((entry) {
      final index = entry.key;
      final o     = entry.value;
      final draggingThis = _dragIndex == index;
      final isDraw = _activeTool == _Tool.draw;
      return Positioned(
        left: (o.position.dx * w).clamp(0.0, w - 10),
        top:  (o.position.dy * h).clamp(0.0, h - 10),
        child: GestureDetector(
          onTap:       isDraw ? null : () => setState(() => _selectedOverlayIndex = index),
          onPanStart:  isDraw ? null : (_) => _onTextDragStart(index),
          onPanUpdate: isDraw ? null : (d) => _onTextDragUpdate(index, d, w, h),
          onPanEnd:    isDraw ? null : (_) => _onTextDragEnd(index, h),
          child: AnimatedOpacity(
            opacity: (draggingThis && _isOverTrash) ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: Stack(clipBehavior: Clip.none, children: [
              Text(o.text, style: overlayShadowStyle(o)),
              Text(o.text, style: overlayTextStyle(o)),
            ]),
          ),
        ),
      );
    }).toList();
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  IconData _toolIcon(_Tool t) {
    switch (t) {
      case _Tool.trim:    return Icons.content_cut_rounded;
      case _Tool.filters: return Icons.auto_fix_high_rounded;
      case _Tool.adjust:  return Icons.tune_rounded;
      case _Tool.draw:    return Icons.brush_rounded;
      case _Tool.text:    return Icons.text_fields_rounded;
      case _Tool.rotate:  return Icons.rotate_90_degrees_cw_rounded;
    }
  }

  String _toolLabel(_Tool t) {
    switch (t) {
      case _Tool.trim:    return 'Trim';
      case _Tool.filters: return 'Filters';
      case _Tool.adjust:  return 'Adjust';
      case _Tool.draw:    return 'Draw';
      case _Tool.text:    return 'Text';
      case _Tool.rotate:  return 'Rotate';
    }
  }
}

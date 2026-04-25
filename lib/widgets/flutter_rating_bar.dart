// RatingBar widget – Instagram story slider style
// + falling "10" celebration for perfect score (test group only)
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';

// =============================================================================
// FALLING NUMBERS OVERLAY  (shown on perfect 10/10 for test group)
// =============================================================================

class _FallingNumber {
  final double xFraction;
  final double startDelay;
  final double fallDuration;
  final double rotation;
  final double fontSize;
  final Color color;

  const _FallingNumber({
    required this.xFraction,
    required this.startDelay,
    required this.fallDuration,
    required this.rotation,
    required this.fontSize,
    required this.color,
  });
}

class _FallingNumbersOverlay extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onComplete;
  const _FallingNumbersOverlay({
    required this.isDarkMode,
    required this.onComplete,
  });

  @override
  State<_FallingNumbersOverlay> createState() => _FallingNumbersOverlayState();
}

class _FallingNumbersOverlayState extends State<_FallingNumbersOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_FallingNumber> _numbers;

  static const _totalDuration = Duration(milliseconds: 2800);
  static const int _count = 22;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();

    final List<Color> palette = widget.isDarkMode
        ? [
            const Color(0xFFFFFFFF),
            const Color(0xFFd9d9d9),
            const Color(0xFFEEEEEE),
            const Color(0xFFBDBDBD),
            const Color(0xFFF5F5F5),
            const Color(0xFFE0E0E0),
          ]
        : [
            const Color(0xFF212121),
            const Color(0xFF424242),
            const Color(0xFF000000),
            const Color(0xFF303030),
            const Color(0xFF1A1A1A),
            const Color(0xFF333333),
          ];

    _numbers = List.generate(_count, (i) {
      return _FallingNumber(
        xFraction: 0.05 + rng.nextDouble() * 0.90,
        startDelay: (i / _count) * 0.55 + rng.nextDouble() * 0.05,
        fallDuration: 0.50 + rng.nextDouble() * 0.30,
        rotation: (rng.nextDouble() - 0.5) * 0.8,
        fontSize: 16 + rng.nextDouble() * 16,
        color: palette[i % palette.length],
      );
    });

    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..forward().whenComplete(() {
        if (mounted) widget.onComplete();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            children: _numbers.map((n) {
              final available = 1.0 - n.startDelay;
              final localT = ((_controller.value - n.startDelay) / available)
                  .clamp(0.0, 1.0);

              if (_controller.value < n.startDelay) {
                return const SizedBox.shrink();
              }

              final yStart = -80.0;
              final yEnd = size.height + 80.0;
              final y = yStart + (yEnd - yStart) * localT;
              final wobble = math.sin(localT * math.pi * 3) * 12;
              final x = n.xFraction * size.width + wobble;

              double opacity;
              if (localT < 0.15) {
                opacity = localT / 0.15;
              } else if (localT < 0.75) {
                opacity = 1.0;
              } else {
                opacity = 1.0 - ((localT - 0.75) / 0.25);
              }

              final scale = 0.4 + 0.6 * math.min(1.0, localT / 0.2);

              final strokePaint = Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = n.fontSize * 0.12
                ..color = n.color.withOpacity(opacity.clamp(0.0, 1.0));

              final fillPaint = Paint()
                ..style = PaintingStyle.fill
                ..color = n.color.withOpacity(opacity.clamp(0.0, 1.0));

              return Positioned(
                left: x - n.fontSize,
                top: y - n.fontSize,
                child: Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: scale,
                    child: Transform.rotate(
                      angle: n.rotation,
                      child: Stack(
                        children: [
                          Text('10',
                              style: TextStyle(
                                  fontSize: n.fontSize,
                                  fontWeight: FontWeight.w900,
                                  fontFamily: 'Inter',
                                  decoration: TextDecoration.none,
                                  foreground: strokePaint)),
                          Text('10',
                              style: TextStyle(
                                  fontSize: n.fontSize,
                                  fontWeight: FontWeight.w900,
                                  fontFamily: 'Inter',
                                  decoration: TextDecoration.none,
                                  foreground: fillPaint)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

// =============================================================================
// HEART-EYES EMOJI THUMB  – fixed size, no scaling
// =============================================================================

class _HeartEyesThumbShape extends SliderComponentShape {
  final double size;

  const _HeartEyesThumbShape({this.size = 32.0});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(size, size);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: '😍', style: TextStyle(fontSize: size, height: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      context.canvas,
      center - Offset(tp.width / 2, tp.height / 2),
    );
  }
}

// =============================================================================
// INSTAGRAM-STYLE PILL TRACK SHAPE
// =============================================================================

class _PillTrackShape extends RoundedRectSliderTrackShape {
  const _PillTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double trackHeight = 10.0;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

// =============================================================================
// RATING BAR
// =============================================================================

class RatingBar extends StatefulWidget {
  final double initialRating;
  final ValueChanged<double>? onRatingUpdate;
  final ValueChanged<double> onRatingEnd;
  final bool hasRated;
  final double userRating;
  final bool showSlider;
  final VoidCallback onEditRating;
  final double averageRating;

  /// Optional override from parent. When null the widget self-resolves
  /// guidance by querying Supabase.
  final bool? showGuidance;

  const RatingBar({
    Key? key,
    this.initialRating = 5.0,
    this.onRatingUpdate,
    required this.onRatingEnd,
    required this.hasRated,
    required this.userRating,
    required this.showSlider,
    required this.onEditRating,
    this.averageRating = 5.0,
    this.showGuidance,
  }) : super(key: key);

  @override
  State<RatingBar> createState() => _RatingBarState();
}

class _RatingBarState extends State<RatingBar> with TickerProviderStateMixin {
  // ── guidance / test-group ─────────────────────────────────────────────────
  bool _guidanceLoaded = false;
  bool _resolvedGuidance = false;
  bool _isTestGroup = false;

  bool get _effectiveShowGuidance => widget.showGuidance ?? _resolvedGuidance;

  // ── controllers ───────────────────────────────────────────────────────────
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  late AnimationController _sliderEntranceController;
  late Animation<double> _sliderSlide;
  late Animation<double> _sliderFade;

  late AnimationController _nudgeController;
  late Animation<double> _nudgeRating;

  late AnimationController _nudgeGlowController;
  late Animation<double> _nudgeGlow;

  bool _isNudging = false;
  late double _currentRating;
  bool _isDragging = false;

  // ── overlay ───────────────────────────────────────────────────────────────
  OverlayEntry? _fallingOverlayEntry;

  ThemeProvider? _lastThemeProvider;

  static const double _nudgeStart = 5.0;
  static const double _nudgePeak = 8.0;

  bool get _shouldNudge =>
      widget.showSlider && !widget.hasRated && _effectiveShowGuidance;

  // ── init ──────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentRating = widget.initialRating;

    _scaleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    _scaleAnimation =
        CurvedAnimation(parent: _scaleController, curve: Curves.elasticOut);

    _sliderEntranceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _sliderSlide = Tween<double>(begin: 12.0, end: 0.0).animate(CurvedAnimation(
        parent: _sliderEntranceController, curve: Curves.easeOut));
    _sliderFade = CurvedAnimation(
        parent: _sliderEntranceController, curve: Curves.easeIn);

    _nudgeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _nudgeRating = TweenSequence<double>([
      TweenSequenceItem(
          tween: ConstantTween<double>(_nudgeStart), weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(begin: _nudgeStart, end: _nudgePeak)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(begin: _nudgePeak, end: _nudgeStart)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: ConstantTween<double>(_nudgeStart), weight: 38.9),
    ]).animate(_nudgeController);

    _nudgeController.addListener(() {
      if (_isNudging && mounted && !_isDragging) {
        setState(() => _currentRating = _nudgeRating.value);
      }
    });

    _nudgeGlowController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _nudgeGlow = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _nudgeGlowController, curve: Curves.easeInOut));

    if (widget.showSlider) {
      _sliderEntranceController.forward().then((_) {
        if (mounted) _loadGuidanceFlag();
      });
    } else if (!widget.showSlider && widget.hasRated) {
      _scaleController.forward();
    }
  }

  // ── Guidance / test-group loader ──────────────────────────────────────────

  Future<void> _loadGuidanceFlag() async {
    if (widget.showGuidance != null) {
      setState(() => _guidanceLoaded = true);
      if (_shouldNudge) _startNudge();
      return;
    }

    try {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      if (user == null) return;

      final supabase = Supabase.instance.client;

      final userRow = await supabase
          .from('users')
          .select('test')
          .eq('uid', user.uid)
          .maybeSingle();

      final bool isTestGroup = userRow?['test'] ?? true;
      final int threshold = isTestGroup ? 3 : 1;

      final ratingsRes = await supabase
          .from('post_rating')
          .select('userid')
          .eq('userid', user.uid);

      final int ratingCount = (ratingsRes as List).length;

      if (!mounted) return;

      setState(() {
        _isTestGroup = isTestGroup;
        _resolvedGuidance = ratingCount < threshold;
        _guidanceLoaded = true;
      });

      if (_shouldNudge) _startNudge();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isTestGroup = true;
          _resolvedGuidance = true;
          _guidanceLoaded = true;
        });
        if (_shouldNudge) _startNudge();
      }
    }
  }

  // ── Falling-10 animation ──────────────────────────────────────────────────

  void _triggerFallingTens() {
    if (!_isTestGroup || !mounted) return;

    _fallingOverlayEntry?.remove();
    _fallingOverlayEntry = null;

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isDark = themeProvider.themeMode == ThemeMode.dark;

    final overlay = Overlay.of(context);
    _fallingOverlayEntry = OverlayEntry(
      builder: (_) => _FallingNumbersOverlay(
        isDarkMode: isDark,
        onComplete: () {
          _fallingOverlayEntry?.remove();
          _fallingOverlayEntry = null;
        },
      ),
    );
    overlay.insert(_fallingOverlayEntry!);
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  void _startNudge() {
    if (_isDragging || !mounted) return;
    setState(() {
      _isNudging = true;
      _currentRating = _nudgeStart;
    });
    _nudgeGlowController.repeat(reverse: true);
    _nudgeController.repeat();
  }

  void _stopNudge() {
    _nudgeController.stop();
    _nudgeGlowController.stop();
    _nudgeGlowController.animateTo(0.0,
        duration: const Duration(milliseconds: 150));
    if (mounted) setState(() => _isNudging = false);
  }

  // ── didUpdateWidget ───────────────────────────────────────────────────────

  @override
  void didUpdateWidget(covariant RatingBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.showSlider && !oldWidget.showSlider) {
      _sliderEntranceController.forward(from: 0.0).then((_) {
        if (mounted) {
          if (_guidanceLoaded) {
            if (_shouldNudge) _startNudge();
          } else {
            _loadGuidanceFlag();
          }
        }
      });
      if (!_isDragging) {
        _currentRating =
            widget.userRating > 0 ? widget.userRating : widget.initialRating;
      }
    }

    if (!widget.showSlider && oldWidget.showSlider) {
      _stopNudge();
      _scaleController.forward(from: 0.0);
    }

    if (!_isDragging && !_isNudging) {
      if (widget.userRating != oldWidget.userRating) {
        _currentRating = widget.userRating;
      }
    }

    if (widget.hasRated && !oldWidget.hasRated && widget.showGuidance == null) {
      _loadGuidanceFlag();
    }
  }

  // ── interaction ───────────────────────────────────────────────────────────

  void _onRatingChanged(double newRating) {
    if (_isNudging) _stopNudge();
    setState(() {
      _currentRating = newRating;
      _isDragging = true;
    });
    widget.onRatingUpdate?.call(newRating);
  }

  void _onRatingEnd(double rating) {
    setState(() => _isDragging = false);

    if (rating >= 10.0 && _isTestGroup) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _triggerFallingTens();
      });
    }

    widget.onRatingEnd(rating);
  }

  // ── dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _fallingOverlayEntry?.remove();
    _fallingOverlayEntry = null;
    _scaleController.dispose();
    _sliderEntranceController.dispose();
    _nudgeController.dispose();
    _nudgeGlowController.dispose();
    super.dispose();
  }

  // ── Average answer display (shown after rating) ───────────────────────────

  Widget _buildAverageDisplay() {
    // Normalise average to 0.0–1.0 across the 1–10 range.
    final double norm = ((widget.averageRating - 1) / 9.0).clamp(0.0, 1.0);

    return ScaleTransition(
      scale: _scaleAnimation,
      child: GestureDetector(
        onTap: widget.onEditRating,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Track + emoji ──────────────────────────────────────────
            SizedBox(
              height: 44,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const double emojiSize = 32.0;
                  const double trackH = 10.0;
                  const double trackVertical = (44 - trackH) / 2;
                  final double usable = constraints.maxWidth - emojiSize;
                  final double emojiLeft = norm * usable;
                  final double fillEnd = emojiLeft + emojiSize / 2;

                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Background track
                      Positioned(
                        top: trackVertical,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: trackH,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.20),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                      // Filled portion
                      Positioned(
                        top: trackVertical,
                        left: 0,
                        width: fillEnd.clamp(0, constraints.maxWidth),
                        child: Container(
                          height: trackH,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                      // Heart-eyes emoji at average position
                      Positioned(
                        left: emojiLeft,
                        top: (44 - emojiSize) / 2,
                        child: Text(
                          '😍',
                          style: TextStyle(
                            fontSize: emojiSize,
                            height: 1.0,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            // ── Label ─────────────────────────────────────────────────
            Text(
              'average answer',
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFamily: 'Inter',
                letterSpacing: 0.1,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Active slider ─────────────────────────────────────────────────────────

  Widget _buildRatingSlider() {
    return AnimatedBuilder(
      animation: _sliderEntranceController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _sliderSlide.value),
          child:
              Opacity(opacity: _sliderFade.value.clamp(0.0, 1.0), child: child),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── "Slide the bar" guidance chip ─────────────────────────
            AnimatedOpacity(
              opacity: _isNudging && _effectiveShowGuidance ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6.0),
                child: AnimatedBuilder(
                  animation: _nudgeGlow,
                  builder: (context, _) {
                    final glow = _nudgeGlow.value;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.9 + 0.1 * glow),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.white.withOpacity(0.35 * glow),
                              blurRadius: 10,
                              spreadRadius: 1),
                        ],
                      ),
                      child: Text(
                        'Slide the bar',
                        style: TextStyle(
                          color: Colors.black.withOpacity(0.75 + 0.25 * glow),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Inter',
                          letterSpacing: 0.2,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // ── Slider ────────────────────────────────────────────────
            AnimatedBuilder(
              animation: Listenable.merge([_nudgeGlow, _nudgeController]),
              builder: (context, child) {
                final double displayRating =
                    _isNudging ? _nudgeRating.value : _currentRating;

                return SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const _HeartEyesThumbShape(size: 32.0),
                    trackShape: const _PillTrackShape(),
                    overlayShape: SliderComponentShape.noOverlay,
                    // No value indicator (no numbers while sliding)
                    showValueIndicator: ShowValueIndicator.never,
                    trackHeight: 10.0,
                    activeTrackColor:
                        Colors.white.withOpacity(_isNudging ? 0.70 : 0.65),
                    inactiveTrackColor: Colors.white.withOpacity(0.20),
                    thumbColor: Colors.transparent,
                  ),
                  child: Slider(
                    value: displayRating.clamp(1.0, 10.0),
                    min: 1.0,
                    max: 10.0,
                    // No divisions → perfectly smooth drag, no snapping
                    onChanged: _onRatingChanged,
                    onChangeEnd: _onRatingEnd,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: !widget.showSlider && widget.hasRated
          ? SizedBox(
              key: const ValueKey('average'),
              width: double.infinity,
              child: _buildAverageDisplay(),
            )
          : widget.showSlider
              ? SizedBox(
                  key: const ValueKey('slider'),
                  width: double.infinity,
                  child: _buildRatingSlider(),
                )
              : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }
}

// RatingBar widget with animations + looping nudge + bouncing arrow
// + falling "10" celebration for perfect score (test group only)
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';

// =============================================================================
// HEART PATH HELPER  (shared by value indicator and rated display)
// =============================================================================

Path _heartPath(Offset center, double size) {
  final double r = size / 2;
  final double cx = center.dx;
  final double cy = center.dy;
  final path = Path();
  // Start at bottom tip
  path.moveTo(cx, cy + r * 0.85);
  // Lower-left curve
  path.cubicTo(cx - r * 0.1, cy + r * 0.45,
               cx - r,        cy + r * 0.25,
               cx - r,        cy - r * 0.10);
  // Upper-left bump
  path.cubicTo(cx - r,        cy - r * 0.60,
               cx - r * 0.45, cy - r,
               cx,            cy - r * 0.35);
  // Upper-right bump
  path.cubicTo(cx + r * 0.45, cy - r,
               cx + r,        cy - r * 0.60,
               cx + r,        cy - r * 0.10);
  // Lower-right curve back to tip
  path.cubicTo(cx + r,        cy + r * 0.25,
               cx + r * 0.10, cy + r * 0.45,
               cx,            cy + r * 0.85);
  path.close();
  return path;
}

// =============================================================================
// HEART VALUE INDICATOR SHAPE
// Replaces the default circle/teardrop tooltip that appears while sliding.
// =============================================================================

class _HeartValueIndicatorShape extends SliderComponentShape {
  const _HeartValueIndicatorShape();

  static const double _heartSize = 44.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size(_heartSize, _heartSize);

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
    final double opacity = activationAnimation.value;
    if (opacity == 0.0) return;

    final canvas = context.canvas;

    // Position the heart centred above the thumb with a small gap.
    final heartCenter = Offset(
      center.dx,
      center.dy - _heartSize * 0.55 - 18,
    );

    // Draw filled red heart.
    canvas.drawPath(
      _heartPath(heartCenter, _heartSize),
      Paint()
        ..color = Colors.red.withOpacity(opacity)
        ..style = PaintingStyle.fill,
    );

    // Draw the number label centred inside the heart.
    labelPainter.paint(
      canvas,
      Offset(
        heartCenter.dx - labelPainter.width / 2,
        heartCenter.dy - labelPainter.height / 2,
      ),
    );
  }
}

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
            const Color(0xFFCFCFCF),
            const Color(0xFFD9D9D9),
            const Color(0xFFF0F0F0),
            const Color(0xFFB0B0B0),
          ]
        : [
            const Color(0xFF212121),
            const Color(0xFF424242),
            const Color(0xFF000000),
            const Color(0xFF303030),
            const Color(0xFF1A1A1A),
            const Color(0xFF333333),
            const Color(0xFF4A4A4A),
            const Color(0xFF222222),
            const Color(0xFF2C2C2C),
            const Color(0xFF3D3D3D),
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
                          Text(
                            '10',
                            style: TextStyle(
                              fontSize: n.fontSize,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'Inter',
                              decoration: TextDecoration.none,
                              foreground: strokePaint,
                            ),
                          ),
                          Text(
                            '10',
                            style: TextStyle(
                              fontSize: n.fontSize,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'Inter',
                              decoration: TextDecoration.none,
                              foreground: fillPaint,
                            ),
                          ),
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
// EMOJI THUMB SHAPE
// =============================================================================

class _EmojiThumbShape extends SliderComponentShape {
  final String emoji;
  final double size;
  final double arrowBounce;
  final double arrowOpacity;
  final bool showArrow;

  const _EmojiThumbShape({
    this.emoji = '👆',
    this.size = 30.0,
    this.arrowBounce = 0.0,
    this.arrowOpacity = 0.0,
    this.showArrow = false,
  });

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
    final canvas = context.canvas;

    if (showArrow && arrowOpacity > 0) {
      const arrowSize = 48.0;
      const arrowScaleY = 2.2;
      const arrowH = arrowSize * arrowScaleY;
      final arrowTop = center.dy - size / 2 - arrowH - 8 - arrowBounce;
      final arrowCenter = Offset(center.dx, arrowTop + arrowH / 2);

      final arrowPainter = TextPainter(
        text: TextSpan(
          text: '↓',
          style: TextStyle(
            fontSize: arrowSize,
            height: 1.0,
            color: Colors.white.withOpacity(arrowOpacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      canvas.save();
      canvas.translate(arrowCenter.dx, arrowCenter.dy);
      canvas.scale(1.0, arrowScaleY);
      canvas.translate(-arrowCenter.dx, -arrowCenter.dy);
      arrowPainter.paint(
        canvas,
        Offset(arrowCenter.dx - arrowPainter.width / 2,
            arrowCenter.dy - arrowPainter.height / 2),
      );
      canvas.restore();
    }

    final tp = TextPainter(
      text:
          TextSpan(text: emoji, style: TextStyle(fontSize: size, height: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
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

  late AnimationController _pulseController;
  late Animation<double> _pulseScale;

  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  late AnimationController _nudgeController;
  late Animation<double> _nudgeRating;
  late Animation<double> _nudgeThumbPos;

  late AnimationController _arrowBounceController;
  late Animation<double> _arrowBounce;

  late AnimationController _nudgeGlowController;
  late Animation<double> _nudgeGlow;

  late AnimationController _iconWiggleController;
  late Animation<double> _iconWiggle;

  bool _isNudging = false;
  late double _currentRating;
  bool _isDragging = false;
  bool _justSubmitted = false;

  // ── overlay ───────────────────────────────────────────────────────────────
  OverlayEntry? _fallingOverlayEntry;

  Color? _cachedSliderActiveColor;
  Color? _cachedSliderInactiveColor;
  ThemeProvider? _lastThemeProvider;

  static const double _nudgeStart = 5.0;
  static const double _nudgePeak = 8.5;

  bool get _shouldNudge =>
      widget.showSlider && !widget.hasRated && _effectiveShowGuidance;

  // ── init ──────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentRating = widget.initialRating.roundToDouble();

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

    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 120));
    _pulseScale = Tween<double>(begin: 1.0, end: 1.18).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));

    _shimmerController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
        CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut));

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

    _nudgeThumbPos = TweenSequence<double>([
      TweenSequenceItem(
          tween: ConstantTween<double>(_ratingToNorm(_nudgeStart)),
          weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(
                  begin: _ratingToNorm(_nudgeStart),
                  end: _ratingToNorm(_nudgePeak))
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(
                  begin: _ratingToNorm(_nudgePeak),
                  end: _ratingToNorm(_nudgeStart))
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: ConstantTween<double>(_ratingToNorm(_nudgeStart)),
          weight: 38.9),
    ]).animate(_nudgeController);

    _nudgeController.addListener(() {
      if (_isNudging && mounted && !_isDragging) {
        setState(() => _currentRating = _nudgeRating.value);
      }
    });

    _arrowBounceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..repeat(reverse: true);
    _arrowBounce = Tween<double>(begin: 0.0, end: 10.0).animate(CurvedAnimation(
        parent: _arrowBounceController, curve: Curves.easeInOut));

    _nudgeGlowController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _nudgeGlow = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _nudgeGlowController, curve: Curves.easeInOut));

    _iconWiggleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _iconWiggle = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: 5.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(begin: 5.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 38.9),
    ]).animate(_iconWiggleController);

    if (widget.showSlider) {
      _sliderEntranceController.forward().then((_) {
        if (mounted) _loadGuidanceFlag();
      });
    } else if (!widget.showSlider && widget.hasRated) {
      _scaleController.forward();
      _justSubmitted = true;
      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _shimmerController.forward(from: 0.0).then((_) {
            if (mounted) setState(() => _justSubmitted = false);
          });
        }
      });
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

      final bool shouldShow = ratingCount < threshold;
      setState(() {
        _isTestGroup = isTestGroup;
        _resolvedGuidance = shouldShow;
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

  double _ratingToNorm(double rating) => (rating - 1) / 9.0;

  void _startNudge() {
    if (_isDragging || !mounted) return;
    setState(() {
      _isNudging = true;
      _currentRating = _nudgeStart;
    });
    _nudgeGlowController.repeat(reverse: true);
    _nudgeController.repeat();
    _iconWiggleController.repeat();
  }

  void _stopNudge() {
    _nudgeController.stop();
    _nudgeGlowController.stop();
    _iconWiggleController.stop();
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
        _currentRating = widget.userRating > 0
            ? widget.userRating.roundToDouble()
            : widget.initialRating.roundToDouble();
      }
    }

    if (!widget.showSlider && oldWidget.showSlider) {
      _stopNudge();
      _scaleController.forward(from: 0.0);
      _justSubmitted = true;
      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _shimmerController.forward(from: 0.0).then((_) {
            if (mounted) setState(() => _justSubmitted = false);
          });
        }
      });
    }

    if (!_isDragging && !_isNudging) {
      if (widget.userRating != oldWidget.userRating) {
        _currentRating = widget.userRating.roundToDouble();
      }
    }

    if (widget.hasRated && !oldWidget.hasRated && widget.showGuidance == null) {
      _loadGuidanceFlag();
    }
  }

  // ── interaction ───────────────────────────────────────────────────────────

  void _onRatingChanged(double newRating) {
    final rounded = newRating.roundToDouble();
    if (_isNudging) _stopNudge();
    setState(() {
      _currentRating = rounded;
      _isDragging = true;
    });
    widget.onRatingUpdate?.call(rounded);
    _pulseController.forward(from: 0.0).then((_) => _pulseController.reverse());
  }

  void _onRatingEnd(double rating) {
    final rounded = rating.roundToDouble();
    setState(() => _isDragging = false);

    if (rounded >= 10.0 && _isTestGroup) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _triggerFallingTens();
      });
    }

    widget.onRatingEnd(rounded);
  }

  // ── colors ────────────────────────────────────────────────────────────────

  void _updateCachedColors(ThemeProvider themeProvider) {
    if (_lastThemeProvider != themeProvider) {
      _lastThemeProvider = themeProvider;
      final isDark = themeProvider.themeMode == ThemeMode.dark;
      _cachedSliderActiveColor =
          isDark ? const Color(0xFFd9d9d9) : Colors.black;
      _cachedSliderInactiveColor =
          isDark ? const Color(0xFF333333) : Colors.grey[400]!;
    }
  }

  // ── dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _fallingOverlayEntry?.remove();
    _fallingOverlayEntry = null;
    _scaleController.dispose();
    _sliderEntranceController.dispose();
    _pulseController.dispose();
    _shimmerController.dispose();
    _nudgeController.dispose();
    _arrowBounceController.dispose();
    _nudgeGlowController.dispose();
    _iconWiggleController.dispose();
    super.dispose();
  }

  // ── "You rated" heart display ─────────────────────────────────────────────
  // Replaces the old pill button. Tapping it still triggers onEditRating.

  Widget _buildRatingButton() {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: GestureDetector(
        onTap: widget.onEditRating,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.favorite, color: Colors.red, size: 56),
            Text(
              widget.userRating.round().toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                fontFamily: 'Inter',
                height: 1.0,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Inline heart rating (right of slider while dragging) ─────────────────

  Widget _buildHeartRating(double rating) {
    return Stack(
      alignment: Alignment.center,
      children: [
        const Icon(Icons.favorite, color: Colors.red, size: 38),
        Text(
          rating.round().toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            fontFamily: 'Inter',
            height: 1.0,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }

  // ── Slider ────────────────────────────────────────────────────────────────

  Widget _buildRatingSlider(ThemeProvider themeProvider) {
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
          children: [
            // ── Guidance chip ─────────────────────────────────────────
            AnimatedOpacity(
              opacity: _isNudging ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 6.0),
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(right: 7),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black
                                  .withOpacity(0.5 + 0.5 * glow),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black
                                        .withOpacity(0.2 * glow),
                                    blurRadius: 4,
                                    spreadRadius: 1)
                              ],
                            ),
                          ),
                          Text(
                            'Slide the bar',
                            style: TextStyle(
                              color: Colors.black
                                  .withOpacity(0.75 + 0.25 * glow),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Inter',
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            // ── Slider row with inline heart ──────────────────────────
            LayoutBuilder(
              builder: (context, constraints) {
                return AnimatedBuilder(
                  animation: Listenable.merge([
                    _nudgeGlow,
                    _arrowBounceController,
                    _nudgeController,
                  ]),
                  builder: (context, child) {
                    final double displayRating =
                        _isNudging ? _nudgeRating.value : _currentRating;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              // ── Heart tooltip while dragging ──────────
                              valueIndicatorShape:
                                  const _HeartValueIndicatorShape(),
                              showValueIndicator:
                                  ShowValueIndicator.always,
                              valueIndicatorTextStyle: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                fontFamily: 'Inter',
                                height: 1.0,
                              ),
                              thumbShape: _effectiveShowGuidance
                                  ? _EmojiThumbShape(
                                      emoji: '👆',
                                      size: 30.0,
                                      showArrow: _isNudging &&
                                          _effectiveShowGuidance,
                                      arrowBounce: _arrowBounce.value,
                                      arrowOpacity: (_isNudging &&
                                              _effectiveShowGuidance)
                                          ? 0.6 + 0.4 * _nudgeGlow.value
                                          : 0.0,
                                    )
                                  : const RoundSliderThumbShape(
                                      enabledThumbRadius: 10.0),
                              overlayShape:
                                  SliderComponentShape.noOverlay,
                              trackHeight: 3.0,
                              activeTrackColor: _isNudging
                                  ? (_cachedSliderActiveColor ??
                                          Colors.white)
                                      .withOpacity(0.85)
                                  : _cachedSliderActiveColor,
                              inactiveTrackColor:
                                  _cachedSliderInactiveColor,
                            ),
                            child: Container(
                              decoration: _isNudging
                                  ? BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                            color: Colors.white.withOpacity(
                                                0.07 * _nudgeGlow.value),
                                            blurRadius: 12,
                                            spreadRadius: 2)
                                      ],
                                    )
                                  : const BoxDecoration(),
                              child: Slider(
                                value: displayRating.clamp(1.0, 10.0),
                                min: 1,
                                max: 10,
                                divisions: 9,
                                label: displayRating.round().toString(),
                                activeColor: _isNudging
                                    ? (_cachedSliderActiveColor ??
                                            Colors.white)
                                        .withOpacity(0.85)
                                    : _cachedSliderActiveColor,
                                inactiveColor: _cachedSliderInactiveColor,
                                onChanged: _onRatingChanged,
                                onChangeEnd: _onRatingEnd,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Inline heart showing the current whole number
                        _buildHeartRating(displayRating),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    _updateCachedColors(themeProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: !widget.showSlider && widget.hasRated
              ? Center(
                  key: const ValueKey('button'), child: _buildRatingButton())
              : widget.showSlider
                  ? SizedBox(
                      key: const ValueKey('slider'),
                      width: double.infinity,
                      child: _buildRatingSlider(themeProvider))
                  : const SizedBox.shrink(key: ValueKey('empty')),
        ),
      ],
    );
  }
}

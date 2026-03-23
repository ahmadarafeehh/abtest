import 'package:flutter/material.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';

class RatingSection extends StatefulWidget {
  final String postId;
  final String userId;
  final List<Map<String, dynamic>> ratings;
  final ValueChanged<double> onRatingEnd;
  final bool showSlider;
  final VoidCallback onEditRating;
  final bool hasRated;
  final double userRating;

  const RatingSection({
    Key? key,
    required this.postId,
    required this.userId,
    required this.ratings,
    required this.onRatingEnd,
    required this.showSlider,
    required this.onEditRating,
    required this.hasRated,
    required this.userRating,
  }) : super(key: key);

  @override
  State<RatingSection> createState() => _RatingSectionState();
}

class _RatingSectionState extends State<RatingSection> {
  double _currentRating = 5.0;

  @override
  Widget build(BuildContext context) {
    double? userRating;

    // Support different naming conventions returned from backend
    for (final rating in widget.ratings) {
      final dynamic rUid =
          rating['userId'] ?? rating['userid'] ?? rating['user_id'];
      if (rUid != null && rUid.toString() == widget.userId) {
        final dynamic rVal = rating['rating'] ?? rating['value'];
        if (rVal is num) {
          userRating = rVal.toDouble();
        } else if (rVal is String) {
          userRating = double.tryParse(rVal);
        }
        break;
      }
    }

    // If there's an existing user rating, prefer it as the initial/current rating
    final initial = userRating ?? _currentRating;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4.0),
        RatingBar(
          initialRating: initial,
          hasRated: widget.hasRated,
          userRating: widget.userRating,
          showSlider: widget.showSlider,
          onEditRating: widget.onEditRating,
          onRatingEnd: (rating) async {
            // call Supabase to persist rating
            final String response = await SupabasePostsMethods().ratePost(
              widget.postId,
              widget.userId,
              rating,
            );

            // avoid using context if widget disposed during await
            if (!mounted) return;

            if (response != 'success') {
              showSnackBar(context, response);
            } else {
              widget.onRatingEnd(rating);
            }
          },
        ),
      ],
    );
  }
}

// rating_stars_display.dart
import 'package:flutter/material.dart';

class RatingStarsDisplay extends StatelessWidget {
  final int rating;
  final double iconSize;

  const RatingStarsDisplay({
    super.key,
    required this.rating,
    this.iconSize = 16.0,
  });

  Color _getColorForRating(int rating) {
    switch (rating) {
      case 1:
      case 2:
        return const Color(0xFFFFD60A);
      case 3:
        return const Color(0xFFFFD60A);
      case 4:
        return const Color(0xFFFFD60A);
      case 5:
        return const Color(0xFFFFD60A);
      default:
        return Colors.grey.shade700;
    }
  }

  @override
Widget build(BuildContext context) {
    if (rating == 0) {
      return const SizedBox.shrink();
    }

    final Color starColor = _getColorForRating(rating);
    final Color outlineColor = const Color.fromARGB(255, 88, 88, 88).withOpacity(0.9);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        return Icon(
          index < rating ? Icons.star : Icons.star_border,
          color: index < rating ? starColor : outlineColor,
          size: iconSize,
          // ¡Adiós a la sombra pesada!
        );
      }),
    );
  }
}
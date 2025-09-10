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
        return const Color.fromARGB(255, 230, 201, 40); // Dorado
      case 3:
        return const Color.fromARGB(255, 230, 201, 40); // Dorado
      case 4:
        return const Color.fromARGB(255, 230, 201, 40); // Dorado
      case 5:
        return const Color.fromARGB(255, 230, 201, 40); // Dorado
      default:
        return Colors.grey.shade700;
    }
  }

  @override
Widget build(BuildContext context) {
  if (rating == 0) {
    return const SizedBox.shrink(); // No muestra nada si no hay calificación
  }

  // --- INICIO DE LA MODIFICACIÓN ---

  // Color para las estrellas RELLENAS (basado en la calificación)
  final Color starColor = _getColorForRating(rating);

  // Color para el CONTORNO de las estrellas (las vacías).
  // ¡Puedes cambiar este color a tu gusto!
  final Color outlineColor = const Color.fromARGB(255, 88, 88, 88).withOpacity(0.9);

  final shadow = Shadow(
    blurRadius: 2.0,
    color: Colors.black.withOpacity(0.7),
    offset: const Offset(1.0, 1.0),
  );

  return Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(5, (index) {
      return Icon(
        index < rating ? Icons.star : Icons.star_border,
        // Condición para aplicar el color correcto a cada tipo de estrella
        color: index < rating ? starColor : outlineColor,
        size: iconSize,
        shadows: [shadow],
      );
    }),
  );
  // --- FIN DE LA MODIFICACIÓN ---
}
}
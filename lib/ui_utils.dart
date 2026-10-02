// ui_utils.dart
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';

class _GlassNotificationManager {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  static void show(BuildContext context, String message, IconData icon, Color iconColor) {
    // 1. Si ya hay una notificación en pantalla, la quitamos inmediatamente
    _currentEntry?.remove();
    _timer?.cancel();

    // 2. Buscamos la capa más alta de la app (por encima de cualquier Dialog)
    final overlayState = Navigator.of(context, rootNavigator: true).overlay;
    if (overlayState == null) return;

    _currentEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          bottom: 40,
          left: 20,
          right: 20,
          child: Material(
            color: Colors.transparent, // Material transparente para evitar fondos grises
            elevation: 0,
            child: Center(
              // 3. Animación de entrada suave
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack, // Efecto rebote sutil
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: value,
                    child: Opacity(
                      opacity: value.clamp(0.0, 1.0),
                      child: child,
                    ),
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF252525).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(20.0),
                        border: Border.all(color: Colors.white12, width: 0.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, color: iconColor, size: 18),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              message,
                              style: const TextStyle(
                                color: Colors.white, 
                                fontSize: 13, 
                                fontWeight: FontWeight.w500
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    // 4. Insertamos la notificación en la capa superior
    overlayState.insert(_currentEntry!);

    // 5. Programamos su destrucción después de 3 segundos
    _timer = Timer(const Duration(seconds: 3), () {
      _currentEntry?.remove();
      _currentEntry = null;
    });
  }
}

// Mantenemos la misma firma de tu función para que NO tengas que 
// cambiar nada en main.dart ni en los demás archivos.
void showGlassSnackBar(BuildContext context, String message, {IconData icon = Icons.check_circle_outline, Color iconColor = const Color(0xFF0A84FF)}) {
  _GlassNotificationManager.show(context, message, icon, iconColor);
}

// ---------------------------------------------------------------------------
// Búsqueda insensible a acentos (ej: "pokemon" encuentra "Pokémon")
// ---------------------------------------------------------------------------

/// Mapa de caracteres acentuados/especiales -> su equivalente "plano".
/// Cubre los acentos y diéresis más comunes en español y otros idiomas
/// latinos (á, é, í, ó, ú, ü, ñ, ç...) tanto en minúscula como en mayúscula.
const Map<String, String> _diacriticsMap = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
  'Á': 'A', 'À': 'A', 'Ä': 'A', 'Â': 'A', 'Ã': 'A', 'Å': 'A', 'Ā': 'A',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e',
  'É': 'E', 'È': 'E', 'Ë': 'E', 'Ê': 'E', 'Ē': 'E', 'Ė': 'E', 'Ę': 'E',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ī': 'i', 'į': 'i',
  'Í': 'I', 'Ì': 'I', 'Ï': 'I', 'Î': 'I', 'Ī': 'I', 'Į': 'I',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
  'Ó': 'O', 'Ò': 'O', 'Ö': 'O', 'Ô': 'O', 'Õ': 'O', 'Ø': 'O', 'Ō': 'O',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ū': 'u', 'ů': 'u',
  'Ú': 'U', 'Ù': 'U', 'Ü': 'U', 'Û': 'U', 'Ū': 'U', 'Ů': 'U',
  'ñ': 'n', 'ń': 'n', 'Ñ': 'N', 'Ń': 'N',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'Ç': 'C', 'Ć': 'C', 'Č': 'C',
  'ý': 'y', 'ÿ': 'y', 'Ý': 'Y', 'Ÿ': 'Y',
  'š': 's', 'ś': 's', 'ş': 's', 'Š': 'S', 'Ś': 'S', 'Ş': 'S',
  'ž': 'z', 'ź': 'z', 'ż': 'z', 'Ž': 'Z', 'Ź': 'Z', 'Ż': 'Z',
  'æ': 'ae', 'Æ': 'AE', 'œ': 'oe', 'Œ': 'OE',
};

/// Quita los acentos/diacríticos de [input], dejando el resto del texto
/// intacto (mayúsculas, espacios, números, etc.).
String removeDiacritics(String input) {
  // Vía rápida: si el texto es solo ASCII (caso de casi todas las etiquetas
  // en inglés) no hay nada que quitar y se devuelve tal cual, sin copiarlo.
  var isAscii = true;
  for (var i = 0; i < input.length; i++) {
    if (input.codeUnitAt(i) > 0x7F) {
      isAscii = false;
      break;
    }
  }
  if (isAscii) return input;

  final buffer = StringBuffer();
  for (final int rune in input.runes) {
    final String? plain = _diacriticsByRune[rune];
    if (plain != null) {
      buffer.write(plain);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Mismo mapa pero indexado por código (evita crear un String por letra).
final Map<int, String> _diacriticsByRune = {
  for (final e in _diacriticsMap.entries) e.key.runes.first: e.value,
};

/// Normaliza un texto para comparaciones de búsqueda: minúsculas y sin
/// acentos. Úsalo tanto en la consulta del usuario como en los campos que
/// vas a comparar, así "pokemon" encuentra "Pokémon", "Pokemon", "POKÉMON", etc.
String normalizeForSearch(String input) => removeDiacritics(input.toLowerCase());
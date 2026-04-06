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
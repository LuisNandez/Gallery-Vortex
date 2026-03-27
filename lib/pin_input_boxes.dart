// lib/pin_input_boxes.dart

import 'package:flutter/material.dart';

class PinInputBoxes extends StatelessWidget {
  final int pinLength;
  final String enteredPin;

  const PinInputBoxes({
    super.key,
    required this.pinLength,
    required this.enteredPin,
  });

  @override
  Widget build(BuildContext context) {
    List<Widget> boxes = [];
    for (int i = 0; i < pinLength; i++) {
      final isFilled = i < enteredPin.length;
      boxes.add(
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 6.0),
          width: 45,
          height: 55,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E), // Fondo oscuro sutil
            border: Border.all(
              color: isFilled ? const Color(0xFF0A84FF) : Colors.white12,
              width: isFilled ? 1.5 : 1.0,
            ),
            borderRadius: BorderRadius.circular(10.0), // Curvatura estilo Mac
            boxShadow: isFilled
                ? [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.15), // Ligero resplandor
                      blurRadius: 6,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              isFilled ? '●' : '',
              // Punto más grande y limpio
              style: const TextStyle(fontSize: 18, color: Colors.white), 
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: boxes,
    );
  }
}
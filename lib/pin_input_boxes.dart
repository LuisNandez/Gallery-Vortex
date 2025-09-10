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
          margin: const EdgeInsets.symmetric(horizontal: 8.0),
          width: 40,
          height: 50,
          decoration: BoxDecoration(
            border: Border.all(
              color: isFilled ? Colors.deepPurpleAccent : Colors.white54,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: Center(
            child: Text(
              isFilled ? '●' : '',
              style: const TextStyle(fontSize: 24, color: Colors.white),
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
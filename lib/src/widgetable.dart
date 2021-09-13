import 'package:flutter/material.dart';

abstract class Widgetable {
  Size get size;

  double get pixelRatio => 1;

  Widget asWidget();
}

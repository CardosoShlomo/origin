import 'resolution.dart';

class Ratio extends Resolution {
  const Ratio(super.x, super.y);

  static const zero = Ratio(0, 0);
  static const square = Ratio(1, 1);
}

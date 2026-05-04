import 'dart:ui';

enum Corner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  double left(Offset delta) => switch (this) {
    topLeft || bottomLeft => delta.dx,
    _ => 0,
  };

  double top(Offset delta) => switch (this) {
    topLeft || topRight => delta.dy,
    _ => 0,
  };

  double right(Offset delta) => switch (this) {
    topRight || bottomRight => delta.dx,
    _ => 0,
  };

  double bottom(Offset delta) => switch (this) {
    bottomLeft || bottomRight => delta.dy,
    _ => 0,
  };
}

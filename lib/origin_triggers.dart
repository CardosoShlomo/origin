class OriginTap {
  const OriginTap();
}

typedef OriginBounds = Map<OriginBound, double>;

enum OriginStart {
  left, right, up, down,
  twoLeft, twoRight, twoUp, twoDown,
  pinchIn, pinchOut;

  OriginBound get bound => switch (this) {
    .left || .twoLeft => .left,
    .right || .twoRight => .right,
    .up || .twoUp => .up,
    .down || .twoDown => .down,
    .pinchIn => .zoomIn,
    .pinchOut => .zoomOut,
  };
}

enum OriginBound {
  left, right, up, down,
  zoomIn, zoomOut,
}

class OriginConstraints {
  const OriginConstraints({
    this.decelerate = 0.03,
    this.frictionLeft = 0,
    this.frictionRight = 0,
    this.frictionUp = 0,
    this.frictionDown = 0,
    this.minScale,
    this.maxScale,
    this.scaleFriction = 0,
  });

  final double decelerate;
  final double frictionLeft;
  final double frictionRight;
  final double frictionUp;
  final double frictionDown;
  final double? minScale;
  final double? maxScale;
  final double scaleFriction;
}

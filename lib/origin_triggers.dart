import 'package:flutter/widgets.dart';

typedef OriginBuilder = Widget Function(BuildContext context, Widget child);

typedef OriginTap = void Function(OriginTapEvent event);

class OriginTapEvent {
  OriginTapEvent({
    required this.localPosition,
    required this.globalPosition,
    required this.animateToBase,
    required this.runEffect,
  });

  final Offset localPosition;
  final Offset globalPosition;
  final Future<void> Function() animateToBase;
  final Future<void> Function({
    double? rotateX,
    double? rotateY,
    double? rotateZ,
    double? perspective,
    Duration duration,
    Curve curve,
  }) runEffect;
}

class OriginBounds {
  const OriginBounds({
    required this.bound,
    this.value = 0,
    this.perspective,
    this.builder,
  });

  const OriginBounds.horizontal({this.value = 0, this.perspective, this.builder}) : bound = OriginBound.horizontal;
  const OriginBounds.vertical({this.value = 0, this.perspective, this.builder}) : bound = OriginBound.vertical;
  const OriginBounds.directional({this.value = 0, this.perspective, this.builder}) : bound = OriginBound.directional;
  const OriginBounds.scale({this.value = 0, this.perspective, this.builder}) : bound = OriginBound.scale;

  final Set<OriginBound> bound;
  final double value;
  final double? perspective;
  final OriginBuilder? builder;
}

enum OriginStart {
  left, right, up, down,
  twoLeft, twoRight, twoUp, twoDown,
  pinchIn, pinchOut;

  static const horizontal = {left, right};
  static const vertical = {up, down};
  static const one = {left, right, up, down};
  static const twoHorizontal = {twoLeft, twoRight};
  static const twoVertical = {twoUp, twoDown};
  static const two = {twoLeft, twoRight, twoUp, twoDown};
  static const scale = {pinchIn, pinchOut};
  static final all = {...values};

  bool get isHorizontal => horizontal.contains(this);
  bool get isVertical => vertical.contains(this);
  bool get isOne => one.contains(this);
  bool get isTwo => two.contains(this);
  bool get isScale => scale.contains(this);

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
  zoomIn, zoomOut;

  static const horizontal = {left, right};
  static const vertical = {up, down};
  static const directional = {left, right, up, down};
  static const scale = {zoomIn, zoomOut};
  static final all = {...values};

  bool get isHorizontal => horizontal.contains(this);
  bool get isVertical => vertical.contains(this);
  bool get isDirectional => directional.contains(this);
  bool get isScale => scale.contains(this);
}

class OriginGesture {
  const OriginGesture({
    required this.start,
    this.bounds = const [],
    this.builder,
  });

  const OriginGesture.horizontal({this.bounds = const [], this.builder}) : start = OriginStart.horizontal;
  const OriginGesture.vertical({this.bounds = const [], this.builder}) : start = OriginStart.vertical;
  const OriginGesture.one({this.bounds = const [], this.builder}) : start = OriginStart.one;
  const OriginGesture.twoHorizontal({this.bounds = const [], this.builder}) : start = OriginStart.twoHorizontal;
  const OriginGesture.twoVertical({this.bounds = const [], this.builder}) : start = OriginStart.twoVertical;
  const OriginGesture.two({this.bounds = const [], this.builder}) : start = OriginStart.two;
  const OriginGesture.scale({this.bounds = const [], this.builder}) : start = OriginStart.scale;
  const OriginGesture.pinchOut({this.bounds = const [], this.builder}) : start = const {.pinchOut};
  const OriginGesture.pinchIn({this.bounds = const [], this.builder}) : start = const {.pinchIn};

  final Set<OriginStart> start;
  final List<OriginBounds> bounds;
  final OriginBuilder? builder;
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

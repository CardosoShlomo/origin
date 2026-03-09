import 'package:flutter/widgets.dart';

typedef StageBuilder = Widget Function(BuildContext context, Widget child);

typedef StageTap = void Function(TapEvent event);

class TapEvent {
  TapEvent({
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

class GestureBounds {
  const GestureBounds({
    required this.bound,
    this.value = 0,
    this.perspective,
    this.builder,
  });

  const GestureBounds.horizontal({this.value = 0, this.perspective, this.builder}) : bound = GestureBound.horizontal;
  const GestureBounds.vertical({this.value = 0, this.perspective, this.builder}) : bound = GestureBound.vertical;
  const GestureBounds.directional({this.value = 0, this.perspective, this.builder}) : bound = GestureBound.directional;
  const GestureBounds.scale({this.value = 0, this.perspective, this.builder}) : bound = GestureBound.scale;

  final Set<GestureBound> bound;
  final double value;
  final double? perspective;
  final StageBuilder? builder;
}

enum GestureStart {
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

  GestureBound get bound => switch (this) {
    .left || .twoLeft => .left,
    .right || .twoRight => .right,
    .up || .twoUp => .up,
    .down || .twoDown => .down,
    .pinchIn => .zoomIn,
    .pinchOut => .zoomOut,
  };
}

enum GestureBound {
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

class Gesture {
  const Gesture({
    required this.start,
    this.bounds = const [],
    this.builder,
  });

  const Gesture.horizontal({this.bounds = const [], this.builder}) : start = GestureStart.horizontal;
  const Gesture.vertical({this.bounds = const [], this.builder}) : start = GestureStart.vertical;
  const Gesture.one({this.bounds = const [], this.builder}) : start = GestureStart.one;
  const Gesture.twoHorizontal({this.bounds = const [], this.builder}) : start = GestureStart.twoHorizontal;
  const Gesture.twoVertical({this.bounds = const [], this.builder}) : start = GestureStart.twoVertical;
  const Gesture.two({this.bounds = const [], this.builder}) : start = GestureStart.two;
  const Gesture.scale({this.bounds = const [], this.builder}) : start = GestureStart.scale;
  const Gesture.pinchOut({this.bounds = const [], this.builder}) : start = const {.pinchOut};
  const Gesture.pinchIn({this.bounds = const [], this.builder}) : start = const {.pinchIn};

  final Set<GestureStart> start;
  final List<GestureBounds> bounds;
  final StageBuilder? builder;
}

class GestureConstraints {
  const GestureConstraints({
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

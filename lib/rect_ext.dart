import 'dart:math';

import 'package:flutter/widgets.dart';
import 'corner.dart';
import 'ratio.dart';
import 'side.dart';

extension RectExt on Rect {
  double get aspectRatio => width / height;
  double get area => width * height;

  double baseWidth(double aspectRatio) => min(width, height * aspectRatio);
  double baseHeight(double aspectRatio) => min(height, width / aspectRatio);

  Rect baseRect(double aspectRatio) {
    return resizeOnCenter(
      baseWidth(aspectRatio),
      baseHeight(aspectRatio),
    );
  }

  Rect copyWithCenter(Offset offset) {
    return Rect.fromCenter(center: offset, width: width, height: height);
  }

  Rect resizeOnCenter(double width, double height) {
    return Rect.fromCenter(center: center, width: width, height: height);
  }

  /// [force] represents the fraction of which we want to force the rect towards the container
  /// when force is equal to one, then the returned rect will be inside the container
  Rect shiftXToFitInside(Rect container, {double force = 1}) {
    assert(0 <= force && force <= 1);
    return translate((getLimitedCenterXInside(container) - center.dx) * force, 0);
  }

  Rect shiftYToFitInside(Rect container, {double force = 1}) {
    assert(0 <= force && force <= 1);
    return translate(0, (getLimitedCenterYInside(container) - center.dy) * force);
  }

  bool isXFitInside(Rect container) {
    return center.dx == getLimitedCenterXInside(container);
  }

  bool isYFitInside(Rect container) {
    return center.dy == getLimitedCenterYInside(container);
  }

  double getLimitedCenterXInside(Rect container) {
    if (width > container.width) {
      return center.dx + min(0, container.left - left) + max(0, container.right - right);
    } else {
      return container.center.dx;
    }
  }

  double getLimitedCenterYInside(Rect container) {
    if (height > container.height) {
      return center.dy + min(0, container.top - top) + max(0, container.bottom - bottom);
    } else {
      return container.center.dy;
    }
  }

  /// check if the rect is going outside of the container
  /// in each axis and apply the (-)friction if true
  Rect getLimitedRect({
    required Rect container,
    required Offset focalPointDelta,
    required Offset friction,
  }) {
    final endX = getLimitedCenterXInside(container);
    final endY = getLimitedCenterYInside(container);

    /// if we need to limit the rect and apply friction on the horizontal axis
    final limitX = endX != center.dx && endX < center.dx == focalPointDelta.dx > 0;
    /// if we need to limit the rect and apply friction on the vertical axis
    final limitY = endY != center.dy && endY < center.dy == focalPointDelta.dy > 0;

    final dx = limitX ? -friction.dx : 0.0;
    final dy = limitY ? -friction.dy : 0.0;
    return translate(dx, dy);
  }

  //todo: implement largest when ratio is not null and make it more responsive
  Rect moveSide({
    required double delta,
    required Side side,
    required Size shortest,
    required Size? longest,
    required double? largest,
    required Rect boundaries,
    required Ratio? ratio,
  }) {
    double l = left, t = top, r = right, b = bottom;
    switch (side) {
      case Side.left:
        l = left + delta;
        if (delta < 0) {
          l = [l, boundaries.left, if (longest != null) right - longest.width, if (largest != null) right - largest/height].reduce(max);
          if (ratio != null) {
            final newWidthPrediction = width - l + left;
            final newHeightPrediction = newWidthPrediction / ratio.aspectRatio;
            final boundaryHeight = longest == null ? boundaries.height : min(boundaries.height, longest.height);
            if (newHeightPrediction > boundaryHeight) {
              l = right - boundaryHeight * ratio.aspectRatio;
              t = boundaries.top;
              b = boundaries.bottom;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
              if (t < boundaries.top) {
                t = boundaries.top;
                b = boundaries.top + newHeightPrediction;
              } else if (b > boundaries.bottom) {
                t = boundaries.bottom - newHeightPrediction;
                b = boundaries.bottom;
              }
            }
          }
        } else {
          l = min(l, right - shortest.width);
          if (ratio != null) {
            final newWidthPrediction = width - l + left;
            final newHeightPrediction = newWidthPrediction / ratio.aspectRatio;
            if (newHeightPrediction < shortest.height) {
              l = right - shortest.height * ratio.aspectRatio;
              t = center.dy - shortest.height/2;
              b = t + shortest.height;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
            }
          }
        }
      case Side.top:
        t = top + delta;
        if (delta < 0) {
          t = [t, boundaries.top, if (longest != null) bottom - longest.height, if (largest != null) bottom - largest/width].reduce(max);
          if (ratio != null) {
            final newHeightPrediction = height - t + top;
            final newWidthPrediction = newHeightPrediction * ratio.aspectRatio;
            final boundaryWidth = longest == null ? boundaries.width : min(boundaries.width, longest.width);
            if (newWidthPrediction > boundaryWidth) {
              t = bottom - boundaryWidth / ratio.aspectRatio;
              l = boundaries.left;
              r = boundaries.right;
            } else {
              l = center.dx - newWidthPrediction/2;
              r = l + newWidthPrediction;
              if (l < boundaries.left) {
                l = boundaries.left;
                r = boundaries.left + newWidthPrediction;
              } else if (r > boundaries.right) {
                l = boundaries.right - newWidthPrediction;
                r = boundaries.right;
              }
            }
          }
        } else {
          t = min(t, bottom - shortest.height);
          if (ratio != null) {
            final newHeightPrediction = height - t + top;
            final newWidthPrediction = newHeightPrediction * ratio.aspectRatio;
            if (newWidthPrediction < shortest.width) {
              t = bottom - shortest.width / ratio.aspectRatio;
              l = center.dx - shortest.width/2;
              r = l + shortest.width;
            } else {
              l = center.dx - newWidthPrediction/2;
              r = l + newWidthPrediction;
            }
          }
        }
      case Side.right:
        r = right + delta;
        if (delta > 0) {
          r = [r, boundaries.right, if (longest != null) left + longest.width, if (largest != null) left + largest/height].reduce(min);
          if (ratio != null) {
            final newWidthPrediction = width + r - right;
            final newHeightPrediction = newWidthPrediction / ratio.aspectRatio;
            final boundaryHeight = longest == null ? boundaries.height : min(boundaries.height, longest.height);
            if (newHeightPrediction > boundaryHeight) {
              r = left + boundaryHeight * ratio.aspectRatio;
              t = boundaries.top;
              b = boundaries.bottom;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
              if (t < boundaries.top) {
                t = boundaries.top;
                b = boundaries.top + newHeightPrediction;
              } else if (b > boundaries.bottom) {
                t = boundaries.bottom - newHeightPrediction;
                b = boundaries.bottom;
              }
            }
          }
        } else {
          r = max(r, left + shortest.width);
          if (ratio != null) {
            final newWidthPrediction = width + r - right;
            final newHeightPrediction = newWidthPrediction / ratio.aspectRatio;
            if (newHeightPrediction < shortest.height) {
              r = left + shortest.height * ratio.aspectRatio;
              t = center.dy - shortest.height/2;
              b = t + shortest.height;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
            }
          }
        }
      case Side.bottom:
        b = bottom + delta;
        if (delta > 0) {
          b = [b, boundaries.bottom, if (longest != null) top + longest.height, if (largest != null) top + largest/width].reduce(min);
          if (ratio != null) {
            final newHeightPrediction = height + b - bottom;
            final newWidthPrediction = newHeightPrediction * ratio.aspectRatio;
            final boundaryWidth = longest == null ? boundaries.width : min(boundaries.width, longest.width);
            if (newWidthPrediction > boundaryWidth) {
              b = top + boundaryWidth / ratio.aspectRatio;
              l = boundaries.left;
              r = boundaries.right;
            } else {
              l = center.dx - newWidthPrediction/2;
              r = l + newWidthPrediction;
              if (l < boundaries.left) {
                l = boundaries.left;
                r = boundaries.left + newWidthPrediction;
              } else if (r > boundaries.right) {
                l = boundaries.right - newWidthPrediction;
                r = boundaries.right;
              }
            }
          }
        } else {
          b = max(b, top + shortest.height);
          if (ratio != null) {
            final newHeightPrediction = height + b - bottom;
            final newWidthPrediction = newHeightPrediction * ratio.aspectRatio;
            if (newWidthPrediction < shortest.width) {
              b = top + shortest.width / ratio.aspectRatio;
              l = center.dx - shortest.width/2;
              r = l + shortest.width;
            } else {
              l = center.dx - newWidthPrediction/2;
              r = l + newWidthPrediction;
            }
          }
        }
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  //todo: implement largest when ratio is not null and make it more responsive
  Rect moveCorner({
    required Offset delta,
    required Corner corner,
    required Size shortest,
    required Size? longest,
    required double? largest,
    required Rect boundaries,
    required Ratio? ratio,
  }) {
    double l = left, t = top, r = right, b = bottom;
    lLarge([double? largest]) => [left + delta.dx, boundaries.left, if (longest != null) right - longest.width, ?largest].reduce(max);
    lEnlarge([double? largest]) => l = lLarge(largest);
    lShort() => min(left + delta.dx, right - shortest.width);
    lShorten() => l = lShort();
    tLarge([double? largest]) => [top + delta.dy, boundaries.top, if (longest != null) bottom - longest.height, ?largest].reduce(max);
    tEnlarge([double? largest]) => t = tLarge(largest);
    tShort() => min(top + delta.dy, bottom - shortest.height);
    tShorten() => t = tShort();
    rLarge([double? largest]) => [right + delta.dx, boundaries.right, if (longest != null) left + longest.width, ?largest].reduce(min);
    rEnlarge([double? largest]) => r = rLarge(largest);
    rShort() => max(right + delta.dx, left + shortest.width);
    rShorten() => r = rShort();
    bLarge([double? largest]) => [bottom + delta.dy, boundaries.bottom, if (longest != null) top + longest.height, ?largest].reduce(min);
    bEnlarge([double? largest]) => b = bLarge(largest);
    bShort() => max(bottom + delta.dy, top + shortest.height);
    bShorten() => b = bShort();
    if (ratio != null) {
      double boundaryX, boundaryY, overflowX, overflowY;
      Function() boundByX, boundByY;
      switch (corner) {
        case Corner.topLeft:
          final part = (delta.dx + delta.dy) / (ratio.x + ratio.y);
          l = left + part * ratio.x;
          t = top + part * ratio.y;
          if (t < top) {
            boundaryX = longest == null ? boundaries.left : max(boundaries.left, right - longest.width);
            boundaryY = longest == null ? boundaries.top : max(boundaries.top, bottom - longest.height);
            overflowX = boundaryX - l;
            overflowY = boundaryY - t;
          } else {
            boundaryX = right - shortest.width;
            boundaryY = bottom - shortest.height;
            overflowX = l - boundaryX;
            overflowY = t - boundaryY;
          }
          boundByX = () {
            l = boundaryX;
            t = bottom - (right - l) / ratio.aspectRatio;
          };
          boundByY = () {
            t = boundaryY;
            l = right - (bottom - t) * ratio.aspectRatio;
          };
        case Corner.topRight:
          final part = (-delta.dx + delta.dy) / (ratio.x + ratio.y);
          t = top + part * ratio.y;
          r = right - part * ratio.x;
          if (t < top) {
            boundaryX = longest == null ? boundaries.right : min(boundaries.right, left + longest.width);
            boundaryY = longest == null ? boundaries.top : max(boundaries.top, bottom - longest.height);
            overflowX = r - boundaryX;
            overflowY = boundaryY - t;
          } else {
            boundaryX = left + shortest.width;
            boundaryY = bottom - shortest.height;
            overflowX = boundaryX - r;
            overflowY = t - boundaryY;
          }
          boundByX = () {
            r = boundaryX;
            t = bottom - (r - left) / ratio.aspectRatio;
          };
          boundByY = () {
            t = boundaryY;
            r = left + (bottom - t) * ratio.aspectRatio;
          };
        case Corner.bottomLeft:
          final part = (-delta.dx + delta.dy) / (ratio.x + ratio.y);
          l = left - part * ratio.x;
          b = bottom + part * ratio.y;
          if (b > bottom) {
            boundaryX = longest == null ? boundaries.left : max(boundaries.left, right - longest.width);
            boundaryY = longest == null ? boundaries.bottom : min(boundaries.bottom, top + longest.height);
            overflowX = boundaryX - l;
            overflowY = b - boundaryY;
          } else {
            boundaryX = right - shortest.width;
            boundaryY = top + shortest.height;
            overflowX = l - boundaryX;
            overflowY = boundaryY - b;
          }
          boundByX = () {
            l = boundaryX;
            b = top + (right - l) / ratio.aspectRatio;
          };
          boundByY = () {
            b = boundaryY;
            l = right - (b - top) * ratio.aspectRatio;
          };
        case Corner.bottomRight:
          final part = (delta.dx + delta.dy) / (ratio.x + ratio.y);
          b = bottom + part * ratio.y;
          r = right + part * ratio.x;
          if (b > bottom) {
            boundaryX = longest == null ? boundaries.right : min(boundaries.right, left + longest.width);
            boundaryY = longest == null ? boundaries.bottom : min(boundaries.bottom, top + longest.height);
            overflowX = r - boundaryX;
            overflowY = b - boundaryY;
          } else {
            boundaryX = left + shortest.width;
            boundaryY = top + shortest.height;
            overflowX = r - boundaryX;
            overflowY = boundaryY - b;
          }
          boundByX = () {
            r = boundaryX;
            b = top + (r - left) / ratio.aspectRatio;
          };
          boundByY = () {
            b = boundaryY;
            r = left + (b - top) * ratio.aspectRatio;
          };
      }
      if (overflowX > 0) {
        if (overflowY > 0) {
          if (overflowX > overflowY) {
            boundByX();
          } else {
            boundByY();
          }
        } else {
          boundByX();
        }
      } else if (overflowY > 0) {
        boundByY();
      }
    } else if (largest != null) {
      largeBound() {
        final y = delta.dy.abs();
        final x = delta.dx.abs();
        double k = 1;
        if (x != 0 && y != 0) {
          /// k == largestDelta.distance / delta.distance
          /// (kx + width)(ky + height) == largest --> Quadratic equation
          k = -height/2/y -width/2/x + sqrt(pow(x * height + y * width, 2) - 4 * x * y * (width * height - largest)) / 2 / x / y;
        } else if (x != 0) {
          k = (largest/height - width) / x;
        } else if (y != 0) {
          k = (largest/width - height) / y;
        }
        if (k < 1) {
          delta = delta * k;
        }
      }
      /// first shorten then enlarge -> thus the enlarge can get more space
      switch (corner) {
        case Corner.topLeft:
          if (delta.dx > 0) {
            lShorten();
            if (delta.dy > 0) {
              tShorten();
            } else {
              tEnlarge(bottom - largest/(right - l));
            }
          } else {
            if (delta.dy > 0) {
              tShorten();
              lEnlarge(right - largest/(bottom - t));
            } else {
              delta = Offset(lLarge(), tLarge()) - topLeft;
              largeBound();
              l = left + delta.dx;
              t = top + delta.dy;
            }
          }
        case Corner.topRight:
          if (delta.dx < 0) {
            rShorten();
            if (delta.dy > 0) {
              tShorten();
            } else {
              tEnlarge(bottom - largest/(r - left));
            }
          } else {
            if (delta.dy > 0) {
              tShorten();
              rEnlarge(left + largest/(bottom - t));
            } else {
              delta = Offset(rLarge(), tLarge()) - topRight;
              largeBound();
              r = right + delta.dx;
              t = top + delta.dy;
            }
          }
        case Corner.bottomLeft:
          if (delta.dx > 0) {
            lShorten();
            if (delta.dy < 0) {
              bShorten();
            } else {
              bEnlarge(top + largest/(right - l));
            }
          } else {
            if (delta.dy < 0) {
              bShorten();
              lEnlarge(right - largest/(b - top));
            } else {
              delta = Offset(lLarge(), bLarge()) - bottomLeft;
              largeBound();
              l = left + delta.dx;
              b = bottom + delta.dy;
            }
          }
        case Corner.bottomRight:
          if (delta.dx < 0) {
            rShorten();
            if (delta.dy < 0) {
              bShorten();
            } else {
              bEnlarge(top + largest/(r - left));
            }
          } else {
            if (delta.dy < 0) {
              bShorten();
              rEnlarge(left + largest/(b - top));
            } else {
              delta = Offset(rLarge(), bLarge()) - bottomRight;
              largeBound();
              r = right + delta.dx;
              b = bottom + delta.dy;
            }
          }
      }
    } else {
      ll() => delta.dx < 0 ? lEnlarge() : lShorten();
      tt() => delta.dy < 0 ? tEnlarge() : tShorten();
      rr() => delta.dx > 0 ? rEnlarge() : rShorten();
      bb() => delta.dy > 0 ? bEnlarge() : bShorten();
      switch (corner) {
        case Corner.topLeft: tt(); ll();
        case Corner.topRight: tt(); rr();
        case Corner.bottomLeft: bb(); ll();
        case Corner.bottomRight: bb(); rr();
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

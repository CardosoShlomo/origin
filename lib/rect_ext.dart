import 'dart:math';

import 'package:flutter/widgets.dart';
import 'corner.dart';
import 'side.dart';

/// Rect transformations in this package pivot on the *center* unless the
/// method name says otherwise. That's the natural choice for animation /
/// gesture math (the center is the point that stays put during scaling),
/// in contrast to Flutter's layout-flavored topLeft convention on
/// [Rect.fromLTRB] / [Rect.fromLTWH].
extension RectExt on Rect {
  double get aspectRatio => width / height;
  double get area => width * height;

  double baseWidth(double aspectRatio) => min(width, height * aspectRatio);
  double baseHeight(double aspectRatio) => min(height, width / aspectRatio);

  Rect baseRect(double aspectRatio) =>
      resize(baseWidth(aspectRatio), baseHeight(aspectRatio));

  /// Same size, new center.
  Rect copyWithCenter(Offset offset) =>
      Rect.fromCenter(center: offset, width: width, height: height);

  /// Same center, new size. Aspect may change.
  Rect resize(double width, double height) =>
      Rect.fromCenter(center: center, width: width, height: height);

  /// Multiply both dimensions by [scale]; aspect preserved, center fixed.
  Rect scale(double scale) => resize(width * scale, height * scale);

  /// Scale so the new width equals [width]; aspect preserved, center fixed.
  Rect scaleToWidth(double width) => scale(width / this.width);

  /// Scale so the new height equals [height]; aspect preserved, center fixed.
  Rect scaleToHeight(double height) => scale(height / this.height);

  /// Clamps `this` (a crop rect) to stay inside [boundaries], optionally
  /// honoring an aspect-ratio range. When a part of the rect spills past
  /// an edge, it's pushed back; if the resulting aspect violates
  /// [minAspectRatio] / [maxAspectRatio], it's resized on its center to
  /// snap back into the allowed range.
  ///
  /// Used by the [Cropper] tool whenever the user drags the crop rect or
  /// the underlying image transforms — keeps the crop rect inside the
  /// image's intersected viewport.
  Rect cropBoundaries(
    Rect boundaries, {
    double? minAspectRatio,
    double? maxAspectRatio,
  }) {
    if (top >= boundaries.top &&
        left >= boundaries.left &&
        bottom <= boundaries.bottom &&
        right <= boundaries.right) {
      return this;
    }
    final w = min(width, boundaries.width);
    final h = min(height, boundaries.height);
    final result = Rect.fromLTRB(
      right >= boundaries.right ? boundaries.right - w : max(boundaries.left, left),
      bottom >= boundaries.bottom ? boundaries.bottom - h : max(boundaries.top, top),
      left <= boundaries.left ? boundaries.left + w : min(boundaries.right, right),
      top <= boundaries.top ? boundaries.top + h : min(boundaries.bottom, bottom),
    );
    final ar = result.width / result.height;
    final lock = minAspectRatio != null && ar < minAspectRatio
        ? minAspectRatio
        : maxAspectRatio != null && ar > maxAspectRatio
            ? maxAspectRatio
            : null;
    if (lock != null) {
      return result.resize(
        min(result.width, result.height * lock),
        min(result.height, result.width / lock),
      );
    }
    return result;
  }

  /// Computes the fit-cover end rect for a double-tap on a displayed
  /// (at-base) view. Scales the rect from BoxFit.contain to BoxFit.cover
  /// (so it fills the display), then pans toward [touchGlobalPosition] on
  /// the overflowing axis (clamped to cover bounds).
  ///
  /// `this` is the displayed container, `baseRect` is the at-base rect
  /// (BoxFit.contain inside `this`).
  ///
  /// [pullFactor] ∈ [0, 1] selects the panning behavior:
  /// - `0` → Apple-style: touched point stays under finger (no edge attraction).
  /// - `1` → ref-style: max edge attraction (taps near the edge snap the
  ///   rect's matching edge against the container edge).
  /// - In between: blended. Clamp is always applied so the rect can't slide
  ///   past cover bounds (would expose container background).
  Rect fitCoverRect(
    Rect baseRect,
    Offset touchGlobalPosition, {
    double pullFactor = 0.4,
  }) {
    final coverScale = area / baseRect.area;
    final coverWidth = baseRect.width * coverScale;
    final coverHeight = baseRect.height * coverScale;
    // "fit by width" = base spans the full container width (height has slack);
    // in cover state, width overflows, so we pan along x. Height-fit is the
    // mirror case.
    final fitByW = (baseRect.width - width).abs() < 0.5;
    final touchPoint = center - touchGlobalPosition;
    // k bridges Apple (coverScale - 1) and ref (coverScale).
    final k = (coverScale - 1) + pullFactor;
    final dxLimit = center.dx * (coverScale - 1);
    final dyLimit = center.dy * (coverScale - 1);
    return Rect.fromCenter(
      center: center.translate(
        fitByW ? (touchPoint.dx * k).clamp(-dxLimit, dxLimit) : 0,
        fitByW ? 0 : (touchPoint.dy * k).clamp(-dyLimit, dyLimit),
      ),
      width: coverWidth,
      height: coverHeight,
    );
  }

  /// Computes the "viewport-correct" end rect for a release-while-displayed.
  /// Mirrors the imagineai `interactionEndRect`:
  /// - Zoomed (scale > 1.02) past [maxScale]: clamp scale to maxScale,
  ///   adjust center proportionally so the same scene stays centered, then
  ///   shift to fit inside [displayRect].
  /// - Zoomed within [maxScale]: shift to fit inside [displayRect] (covers
  ///   display when rect is bigger than display).
  /// - Not zoomed: return [baseRect] (snap to base).
  Rect viewportEndRect(Rect baseRect, Rect displayRect, {double? maxScale}) {
    final scale = width / baseRect.width;
    if (scale <= 1.02) return baseRect;
    Rect target = this;
    if (maxScale != null && scale > maxScale) {
      final ratio = (baseRect.width * maxScale) / width;
      final newCenter =
          (center - displayRect.center) * ratio + displayRect.center;
      target = resize(
        baseRect.width * maxScale,
        baseRect.height * maxScale,
      ).copyWithCenter(newCenter);
    }
    return target.shiftXToFitInside(displayRect).shiftYToFitInside(displayRect);
  }

  /// [force] ∈ [0, 1]: how much to pull the rect back inside [container].
  /// 0 = no movement, 1 = fully inside.
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

  /// Applies per-axis friction damping when the rect's edges cross the
  /// container in the direction of [focalPointDelta].
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

  //todo: implement largest when aspectRatio is not null and make it more responsive
  Rect moveSide({
    required double delta,
    required Side side,
    required Size shortest,
    required Size? longest,
    required double? largest,
    required Rect boundaries,
    required double? aspectRatio,
  }) {
    double l = left, t = top, r = right, b = bottom;
    switch (side) {
      case .left:
        l = left + delta;
        if (delta < 0) {
          l = [l, boundaries.left, if (longest != null) right - longest.width, if (largest != null) right - largest/height].reduce(max);
          if (aspectRatio != null) {
            final newWidthPrediction = width - l + left;
            final newHeightPrediction = newWidthPrediction / aspectRatio;
            final boundaryHeight = longest == null ? boundaries.height : min(boundaries.height, longest.height);
            if (newHeightPrediction > boundaryHeight) {
              l = right - boundaryHeight * aspectRatio;
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
          if (aspectRatio != null) {
            final newWidthPrediction = width - l + left;
            final newHeightPrediction = newWidthPrediction / aspectRatio;
            if (newHeightPrediction < shortest.height) {
              l = right - shortest.height * aspectRatio;
              t = center.dy - shortest.height/2;
              b = t + shortest.height;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
            }
          }
        }
      case .top:
        t = top + delta;
        if (delta < 0) {
          t = [t, boundaries.top, if (longest != null) bottom - longest.height, if (largest != null) bottom - largest/width].reduce(max);
          if (aspectRatio != null) {
            final newHeightPrediction = height - t + top;
            final newWidthPrediction = newHeightPrediction * aspectRatio;
            final boundaryWidth = longest == null ? boundaries.width : min(boundaries.width, longest.width);
            if (newWidthPrediction > boundaryWidth) {
              t = bottom - boundaryWidth / aspectRatio;
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
          if (aspectRatio != null) {
            final newHeightPrediction = height - t + top;
            final newWidthPrediction = newHeightPrediction * aspectRatio;
            if (newWidthPrediction < shortest.width) {
              t = bottom - shortest.width / aspectRatio;
              l = center.dx - shortest.width/2;
              r = l + shortest.width;
            } else {
              l = center.dx - newWidthPrediction/2;
              r = l + newWidthPrediction;
            }
          }
        }
      case .right:
        r = right + delta;
        if (delta > 0) {
          r = [r, boundaries.right, if (longest != null) left + longest.width, if (largest != null) left + largest/height].reduce(min);
          if (aspectRatio != null) {
            final newWidthPrediction = width + r - right;
            final newHeightPrediction = newWidthPrediction / aspectRatio;
            final boundaryHeight = longest == null ? boundaries.height : min(boundaries.height, longest.height);
            if (newHeightPrediction > boundaryHeight) {
              r = left + boundaryHeight * aspectRatio;
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
          if (aspectRatio != null) {
            final newWidthPrediction = width + r - right;
            final newHeightPrediction = newWidthPrediction / aspectRatio;
            if (newHeightPrediction < shortest.height) {
              r = left + shortest.height * aspectRatio;
              t = center.dy - shortest.height/2;
              b = t + shortest.height;
            } else {
              t = center.dy - newHeightPrediction/2;
              b = t + newHeightPrediction;
            }
          }
        }
      case .bottom:
        b = bottom + delta;
        if (delta > 0) {
          b = [b, boundaries.bottom, if (longest != null) top + longest.height, if (largest != null) top + largest/width].reduce(min);
          if (aspectRatio != null) {
            final newHeightPrediction = height + b - bottom;
            final newWidthPrediction = newHeightPrediction * aspectRatio;
            final boundaryWidth = longest == null ? boundaries.width : min(boundaries.width, longest.width);
            if (newWidthPrediction > boundaryWidth) {
              b = top + boundaryWidth / aspectRatio;
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
          if (aspectRatio != null) {
            final newHeightPrediction = height + b - bottom;
            final newWidthPrediction = newHeightPrediction * aspectRatio;
            if (newWidthPrediction < shortest.width) {
              b = top + shortest.width / aspectRatio;
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

  //todo: implement largest when aspectRatio is not null and make it more responsive
  Rect moveCorner({
    required Offset delta,
    required Corner corner,
    required Size shortest,
    required Size? longest,
    required double? largest,
    required Rect boundaries,
    required double? aspectRatio,
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
    if (aspectRatio != null) {
      double boundaryX, boundaryY, overflowX, overflowY;
      Function() boundByX, boundByY;
      final denom = aspectRatio + 1.0;
      switch (corner) {
        case .topLeft:
          final part = (delta.dx + delta.dy) / denom;
          l = left + part * aspectRatio;
          t = top + part;
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
            t = bottom - (right - l) / aspectRatio;
          };
          boundByY = () {
            t = boundaryY;
            l = right - (bottom - t) * aspectRatio;
          };
        case .topRight:
          final part = (-delta.dx + delta.dy) / denom;
          t = top + part;
          r = right - part * aspectRatio;
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
            t = bottom - (r - left) / aspectRatio;
          };
          boundByY = () {
            t = boundaryY;
            r = left + (bottom - t) * aspectRatio;
          };
        case .bottomLeft:
          final part = (-delta.dx + delta.dy) / denom;
          l = left - part * aspectRatio;
          b = bottom + part;
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
            b = top + (right - l) / aspectRatio;
          };
          boundByY = () {
            b = boundaryY;
            l = right - (b - top) * aspectRatio;
          };
        case .bottomRight:
          final part = (delta.dx + delta.dy) / denom;
          b = bottom + part;
          r = right + part * aspectRatio;
          if (b > bottom) {
            boundaryX = longest == null ? boundaries.right : min(boundaries.right, left + longest.width);
            boundaryY = longest == null ? boundaries.bottom : min(boundaries.bottom, top + longest.height);
            overflowX = r - boundaryX;
            overflowY = b - boundaryY;
          } else {
            boundaryX = left + shortest.width;
            boundaryY = top + shortest.height;
            overflowX = boundaryX - r;
            overflowY = boundaryY - b;
          }
          boundByX = () {
            r = boundaryX;
            b = top + (r - left) / aspectRatio;
          };
          boundByY = () {
            b = boundaryY;
            r = left + (b - top) * aspectRatio;
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
        case .topLeft:
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
        case .topRight:
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
        case .bottomLeft:
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
        case .bottomRight:
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
        case .topLeft: tt(); ll();
        case .topRight: tt(); rr();
        case .bottomLeft: bb(); ll();
        case .bottomRight: bb(); rr();
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

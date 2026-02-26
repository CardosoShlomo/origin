import 'package:flutter/widgets.dart';

extension OriginContext on BuildContext {
  Rect get rect {
    final box = findRenderObject() as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

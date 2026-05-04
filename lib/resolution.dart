class Resolution {
  const Resolution(this.x, this.y);

  final int x;
  final int y;

  double get aspectRatio => x / y;

  @override
  bool operator ==(Object other) =>
      other is Resolution && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Resolution($x, $y)';
}

import 'dart:math';

/// Ultra-fast XorShift32 RNG for hot loops, implementing dart:math Random.
class FastRng implements Random {
  int _state;

  FastRng([int seed = 0x12345678]) : _state = seed == 0 ? 1 : seed;

  @pragma('vm:prefer-inline')
  int _next() {
    int x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= (x >> 17);
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x;
    return x;
  }

  @override
  @pragma('vm:prefer-inline')
  int nextInt(int max) {
    if (max <= 0) return 0;
    return (_next() & 0x7FFFFFFF) % max;
  }

  @override
  @pragma('vm:prefer-inline')
  bool nextBool() {
    return (_next() & 1) == 0;
  }

  @override
  @pragma('vm:prefer-inline')
  double nextDouble() {
    return (_next() & 0x7FFFFFFF) / 0x7FFFFFFF;
  }
}

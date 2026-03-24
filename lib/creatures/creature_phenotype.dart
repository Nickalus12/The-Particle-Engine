/// Pre-computed integer visual traits derived from genome + species.
///
/// Computed once at spawn time. All fields are ints for zero-allocation
/// rendering in hot loops.
class CreaturePhenotype {
  final int bodyLength;
  final int bodyWidth;
  final int headBrightness;
  final int legCount;
  final int legAlphaBase;
  final int antennaeLength;
  final int abdomenExtra;
  final int hueShiftR;
  final int hueShiftG;
  final int hueShiftB;
  final int carapaceShine;
  final int wingSize;
  final int glowIntensity;
  final int glowPhaseOffset;
  final int segmentCount;
  final int animSpeed;

  const CreaturePhenotype({
    this.bodyLength = 2,
    this.bodyWidth = 1,
    this.headBrightness = 10,
    this.legCount = 0,
    this.legAlphaBase = 30,
    this.antennaeLength = 0,
    this.abdomenExtra = 0,
    this.hueShiftR = 0,
    this.hueShiftG = 0,
    this.hueShiftB = 0,
    this.carapaceShine = 0,
    this.wingSize = 0,
    this.glowIntensity = 0,
    this.glowPhaseOffset = 0,
    this.segmentCount = 0,
    this.animSpeed = 4,
  });

  // ---------------------------------------------------------------------------
  // Hash helpers (deterministic, no allocation)
  // ---------------------------------------------------------------------------

  static int _hash1(int seed) => ((seed * 2654435761) >> 20) & 0x3F;
  static int _hash2(int seed) => ((seed * 374761393) >> 20) & 0x3F;
  static int _hash3(int seed) => ((seed * 668265263) >> 20) & 0x3F;

  static double _bv(List<double>? behavior, int index, double fallback) {
    if (behavior == null || index >= behavior.length) return fallback;
    return behavior[index];
  }

  // ---------------------------------------------------------------------------
  // Queen: 3-4px, large abdomen, distinctive crown marking, brighter
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forQueen(List<double>? behavior, int genomeSeed) {
    final social = _bv(behavior, 1, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 3 + (resource > 0.5 ? 1 : 0),
      bodyWidth: 2,
      headBrightness: 40 + (social * 30).round(),
      legCount: 4,
      legAlphaBase: 50,
      antennaeLength: 2,
      abdomenExtra: 2,
      hueShiftR: _hash1(genomeSeed) - 10,
      hueShiftG: _hash2(genomeSeed) - 10,
      hueShiftB: _hash3(genomeSeed) - 10,
      carapaceShine: 25,
      wingSize: 0,
      glowIntensity: 15,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 6, // Slow, regal movement.
    );
  }

  // ---------------------------------------------------------------------------
  // Ant: 2-3px, head + abdomen, 4 legs, antennae
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forAnt(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 2 + (envMod > 0.7 ? 1 : 0),
      bodyWidth: 1,
      headBrightness: 10 + (social * 30).round(),
      legCount: 4,
      legAlphaBase: 30 + (social * 40).round(),
      antennaeLength: social > 0.6 ? 2 : 1,
      abdomenExtra: resource > 0.6 ? 1 : 0,
      hueShiftR: _hash1(genomeSeed) - 20,
      hueShiftG: _hash2(genomeSeed) - 20,
      hueShiftB: _hash3(genomeSeed) - 20,
      carapaceShine: (envMod * 20).round(),
      wingSize: 0,
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 3 + (temporal * 5).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Worm: 4-6px segmented chain, sine undulation
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forWorm(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 4 + (resource * 2).round(),
      bodyWidth: 1,
      headBrightness: 20 + (social * 20).round(),
      legCount: 0,
      legAlphaBase: 0,
      antennaeLength: 0,
      abdomenExtra: 0,
      hueShiftR: _hash1(genomeSeed) - 15,
      hueShiftG: _hash2(genomeSeed) - 10,
      hueShiftB: _hash3(genomeSeed) - 15,
      carapaceShine: 0,
      wingSize: 0,
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 3 + (envMod * 3).round(),
      animSpeed: 4 + (temporal * 4).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Beetle: 2x1px, dark shell with specular shine
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forBeetle(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 2,
      bodyWidth: envMod > 0.6 ? 2 : 1,
      headBrightness: 5 + (social * 15).round(),
      legCount: 4,
      legAlphaBase: 20 + (social * 30).round(),
      antennaeLength: 0,
      abdomenExtra: resource > 0.5 ? 1 : 0,
      hueShiftR: _hash1(genomeSeed) - 20,
      hueShiftG: _hash2(genomeSeed) - 20,
      hueShiftB: _hash3(genomeSeed) - 20,
      carapaceShine: 10 + (envMod * 20).round(),
      wingSize: 0,
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 2 + (temporal * 4).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Spider: 1px body + 4 diagonal legs, brighter in dark
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forSpider(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);

    return CreaturePhenotype(
      bodyLength: 1,
      bodyWidth: 1,
      headBrightness: 5 + (social * 10).round(),
      legCount: 4,
      legAlphaBase: 25 + (social * 15).round(),
      antennaeLength: 0,
      abdomenExtra: 0,
      hueShiftR: _hash1(genomeSeed) - 10,
      hueShiftG: _hash2(genomeSeed) - 10,
      hueShiftB: _hash3(genomeSeed) - 10,
      carapaceShine: (envMod * 10).round(),
      wingSize: 0,
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 2 + (temporal * 3).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Fish: 2px + tail wag, blue-shifted, scale shimmer
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forFish(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 2 + (resource > 0.7 ? 1 : 0),
      bodyWidth: 1,
      headBrightness: 15 + (social * 25).round(),
      legCount: 0,
      legAlphaBase: 0,
      antennaeLength: 0,
      abdomenExtra: 0,
      hueShiftR: _hash1(genomeSeed) - 15,
      hueShiftG: _hash2(genomeSeed) - 10,
      hueShiftB: (_hash3(genomeSeed) - 10) + 10, // blue-shifted
      carapaceShine: 5 + (envMod * 15).round(),
      wingSize: 0,
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 3 + (temporal * 4).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Bee: 1px + wing blur, yellow/amber stripe impression
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forBee(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);
    final resource = _bv(behavior, 3, 0.5);

    return CreaturePhenotype(
      bodyLength: 1,
      bodyWidth: 1,
      headBrightness: 20 + (social * 20).round(),
      legCount: 2,
      legAlphaBase: 20,
      antennaeLength: social > 0.5 ? 1 : 0,
      abdomenExtra: resource > 0.6 ? 1 : 0,
      hueShiftR: _hash1(genomeSeed) - 10,
      hueShiftG: _hash2(genomeSeed) - 10,
      hueShiftB: _hash3(genomeSeed) - 20,
      carapaceShine: (envMod * 10).round(),
      wingSize: 1 + (envMod > 0.5 ? 1 : 0),
      glowIntensity: 0,
      glowPhaseOffset: 0,
      segmentCount: 0,
      animSpeed: 2 + (temporal * 3).round(),
    );
  }

  // ---------------------------------------------------------------------------
  // Firefly: 1px + glow halo, Kuramoto sync
  // ---------------------------------------------------------------------------

  factory CreaturePhenotype.forFirefly(List<double>? behavior, int genomeSeed) {
    final envMod = _bv(behavior, 0, 0.5);
    final social = _bv(behavior, 1, 0.5);
    final temporal = _bv(behavior, 2, 0.5);

    return CreaturePhenotype(
      bodyLength: 1,
      bodyWidth: 1,
      headBrightness: 5 + (social * 10).round(),
      legCount: 2,
      legAlphaBase: 20,
      antennaeLength: 0,
      abdomenExtra: 0,
      hueShiftR: _hash1(genomeSeed) - 5,
      hueShiftG: _hash2(genomeSeed) - 5,
      hueShiftB: _hash3(genomeSeed) - 15,
      carapaceShine: 0,
      wingSize: 1,
      glowIntensity: 80 + (envMod * 120).round(),
      glowPhaseOffset: genomeSeed & 0xFF,
      segmentCount: 0,
      animSpeed: 4 + (temporal * 4).round(),
    );
  }
}

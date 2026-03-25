import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';

import '../simulation/element_registry.dart';
import '../simulation/simulation_engine.dart';

/// GPU-accelerated post-processing pipeline for Radiance Cascades 2D Global
/// Illumination, dual Kawase bloom, and ACES filmic tone mapping.
///
/// This component loads 7 fragment shader programs and orchestrates a
/// multi-pass rendering pipeline each frame:
///   1. Build occluder + emitter maps from the simulation grid (CPU)
///   2. JFA: seed + 9 ping-pong flood-fill passes
///   3. Distance field from JFA
///   4. Radiance Cascades: 4 cascade levels (coarse to fine)
///   5. Bloom: 4 downsample + 4 upsample passes (dual Kawase)
///   6. Tone map: composite scene + GI + bloom with ACES + day/night grading
///
/// The luminance array on the [SimulationEngine] is updated every 8 frames
/// from the final GI result so the simulation layer can use light levels
/// for photosynthesis, creature vision, etc.
class GIPostProcess extends Component {
  GIPostProcess({
    required this.simulation,
    this.enabled = true,
  });

  final SimulationEngine simulation;

  /// Master toggle — when false, shaders are not run and the scene passes
  /// through unmodified. Can be toggled at runtime for performance.
  bool enabled;

  /// Strength of the GI contribution (0.0 - 1.0).
  double giStrength = 0.4;

  /// Strength of the bloom effect (0.0 - 1.0).
  double bloomStrength = 0.15;

  /// Bloom brightness threshold — only pixels brighter than this contribute.
  double bloomThreshold = 0.85;

  /// Tone mapping exposure multiplier.
  double exposure = 0.8;

  /// Day/night transition value (0.0 = day, 1.0 = night).
  double dayNightT = 0.0;

  // -- Shader programs --------------------------------------------------------

  ui.FragmentProgram? _jfaSeedProg;
  ui.FragmentProgram? _jfaStepProg;
  ui.FragmentProgram? _distFieldProg;
  ui.FragmentProgram? _radianceCascadeProg;
  ui.FragmentProgram? _bloomDownProg;
  ui.FragmentProgram? _bloomUpProg;
  ui.FragmentProgram? _tonemapProg;

  bool _shadersLoaded = false;
  bool _shaderLoadFailed = false;

  // -- Render targets (ping-pong buffers) ------------------------------------

  /// Grid dimensions — cached from simulation on load.
  late final int _gridW;
  late final int _gridH;

  /// Pixel buffers for CPU-built occluder and emitter maps.
  late Uint8List _occluderPixels;
  late Uint8List _emitterPixels;

  /// Frame counter for throttled luminance readback.
  int _frameCount = 0;

  // -- Constants --------------------------------------------------------------

  /// Number of JFA flood-fill iterations. For a 320-wide grid, log2(320) ~ 9.
  static const int _jfaSteps = 9;

  /// Number of radiance cascade levels (coarse to fine).
  static const int _cascadeLevels = 4;

  /// Number of bloom downsample/upsample passes.
  static const int _bloomPasses = 4;

  /// Maximum ray distance for the distance field and radiance cascades.
  static const double _maxDistance = 64.0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _gridW = simulation.gridW;
    _gridH = simulation.gridH;

    _occluderPixels = Uint8List(_gridW * _gridH * 4);
    _emitterPixels = Uint8List(_gridW * _gridH * 4);

    await _loadShaders();
  }

  @override
  void onRemove() {
    _jfaSeedProg = null;
    _jfaStepProg = null;
    _distFieldProg = null;
    _radianceCascadeProg = null;
    _bloomDownProg = null;
    _bloomUpProg = null;
    _tonemapProg = null;
    _shadersLoaded = false;
    super.onRemove();
  }

  Future<void> _loadShaders() async {
    try {
      final results = await Future.wait([
        ui.FragmentProgram.fromAsset('assets/shaders/jfa_seed.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/jfa_step.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/distance_field.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/radiance_cascade.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/bloom_downsample.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/bloom_upsample.frag'),
        ui.FragmentProgram.fromAsset('assets/shaders/tonemap.frag'),
      ]);

      _jfaSeedProg = results[0];
      _jfaStepProg = results[1];
      _distFieldProg = results[2];
      _radianceCascadeProg = results[3];
      _bloomDownProg = results[4];
      _bloomUpProg = results[5];
      _tonemapProg = results[6];

      _shadersLoaded = true;
    } catch (e) {
      // Shader compilation failed (e.g., on web or unsupported GPU).
      // The pipeline gracefully degrades — scene renders without post-processing.
      _shaderLoadFailed = true;
    }
  }

  // ---------------------------------------------------------------------------
  // CPU map building — occluder + emitter maps from grid state
  // ---------------------------------------------------------------------------

  /// Build the occluder map: solid elements are opaque (alpha = 1),
  /// transparent elements are clear (alpha = 0). RGB is unused.
  void _buildOccluderMap() {
    final grid = simulation.grid;
    final total = _gridW * _gridH;
    final px = _occluderPixels;

    for (int i = 0; i < total; i++) {
      final el = grid[i];
      final pi4 = i * 4;

      // Occluders: solid elements block light, translucent ones partially transmit.
      // Gases and empty are fully transparent. Glass/water/ice are partial occluders.
      int occlusion;
      if (el == El.empty ||
          el == El.fire ||
          el == El.smoke ||
          el == El.steam ||
          el == El.bubble ||
          el == El.lightning ||
          el == El.spore ||
          el == El.oxygen ||
          el == El.co2 ||
          el == El.methane ||
          el == El.hydrogen) {
        occlusion = 0;
      } else if (el == El.glass) {
        occlusion = 40; // ~15% opacity — light transmits through glass
      } else if (el == El.water) {
        occlusion = 100; // ~40% opacity — water attenuates but transmits light
      } else if (el == El.ice) {
        occlusion = 80; // ~30% opacity — ice is translucent
      } else {
        occlusion = 255; // Fully opaque
      }

      px[pi4] = 0;
      px[pi4 + 1] = 0;
      px[pi4 + 2] = 0;
      px[pi4 + 3] = occlusion;
    }
  }

  /// Build the emitter map: light-emitting elements store their color in RGB
  /// and emission intensity in alpha.
  void _buildEmitterMap() {
    final grid = simulation.grid;
    final total = _gridW * _gridH;
    final px = _emitterPixels;

    for (int i = 0; i < total; i++) {
      final el = grid[i];
      final pi4 = i * 4;

      final emission = elementLightEmission[el];
      if (emission > 0) {
        px[pi4] = elementLightR[el];
        px[pi4 + 1] = elementLightG[el];
        px[pi4 + 2] = elementLightB[el];
        px[pi4 + 3] = emission;
      } else {
        // Check heated solids (stone/metal with velX > 2 signals heat).
        final isHeatedSolid =
            (el == El.stone || el == El.metal) && simulation.velX[i] > 2;
        if (isHeatedSolid) {
          final heatLevel = simulation.velX[i].clamp(0, 5);
          px[pi4] = 255;
          px[pi4 + 1] = el == El.metal ? 100 : 80;
          px[pi4 + 2] = el == El.metal ? 20 : 0;
          px[pi4 + 3] = (heatLevel * 40).clamp(0, 200);
        } else {
          px[pi4] = 0;
          px[pi4 + 1] = 0;
          px[pi4 + 2] = 0;
          px[pi4 + 3] = 0;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Full post-processing pipeline
  // ---------------------------------------------------------------------------

  /// Run the full GI + bloom + tonemap pipeline on a scene image.
  /// Returns the final composited image, or [sceneImage] unchanged if
  /// shaders are unavailable.
  Future<ui.Image> process(ui.Image sceneImage) async {
    if (!enabled || !_shadersLoaded || _shaderLoadFailed) {
      return sceneImage;
    }

    _frameCount++;

    // Step 1: Build CPU maps from simulation grid.
    _buildOccluderMap();
    _buildEmitterMap();

    final occluderImage = await _imageFromPixels(_occluderPixels, _gridW, _gridH);
    final emitterImage = await _imageFromPixels(_emitterPixels, _gridW, _gridH);

    final resolution = Float64List.fromList([_gridW.toDouble(), _gridH.toDouble()]);

    // Step 2: JFA seed pass.
    ui.Image jfaResult = await _runJFASeed(occluderImage, resolution);

    // Step 3: JFA flood-fill — 9 ping-pong passes with decreasing step size.
    for (int i = 0; i < _jfaSteps; i++) {
      final stepSize = (1 << (_jfaSteps - 1 - i)).toDouble();
      final nextJFA = await _runJFAStep(jfaResult, resolution, stepSize);
      jfaResult.dispose();
      jfaResult = nextJFA;
    }

    // Step 4: Distance field from JFA.
    final distField = await _runDistanceField(jfaResult, occluderImage, resolution);
    jfaResult.dispose();
    occluderImage.dispose();

    // Step 5: Radiance Cascades — 4 levels, coarse to fine.
    ui.Image giResult = await _createBlackImage(_gridW, _gridH);
    for (int level = _cascadeLevels - 1; level >= 0; level--) {
      final maxDist = _maxDistance * (1 << level).toDouble();
      final nextGI = await _runRadianceCascade(
        distField, emitterImage, giResult, resolution,
        level.toDouble(), _cascadeLevels.toDouble(), maxDist,
      );
      giResult.dispose();
      giResult = nextGI;
    }
    distField.dispose();
    emitterImage.dispose();

    // Step 6: Bloom — downsample chain.
    final bloomChain = <ui.Image>[];
    ui.Image bloomSrc = sceneImage;
    int bw = _gridW;
    int bh = _gridH;

    for (int i = 0; i < _bloomPasses; i++) {
      bw = (bw / 2).ceil().clamp(1, 9999);
      bh = (bh / 2).ceil().clamp(1, 9999);
      final down = await _runBloomDownsample(
        bloomSrc,
        bw.toDouble(), bh.toDouble(),
        i == 0 ? 1.0 : 0.0, // isFirstPass
        bloomThreshold,
      );
      bloomChain.add(down);
      bloomSrc = down;
    }

    // Bloom — upsample chain (reverse, blending into each level).
    for (int i = _bloomPasses - 2; i >= 0; i--) {
      final dstW = i > 0 ? bloomChain[i - 1].width : _gridW;
      final dstH = i > 0 ? bloomChain[i - 1].height : _gridH;
      final dst = i > 0 ? bloomChain[i - 1] : sceneImage;
      final srcTexelW = 1.0 / bloomChain[i + 1].width;
      final srcTexelH = 1.0 / bloomChain[i + 1].height;

      final up = await _runBloomUpsample(
        bloomChain[i + 1], dst,
        dstW.toDouble(), dstH.toDouble(),
        srcTexelW, srcTexelH,
        bloomStrength,
      );

      // Replace in chain.
      if (i > 0) {
        bloomChain[i - 1].dispose();
        bloomChain[i - 1] = up;
      } else {
        bloomChain.insert(0, up);
      }
    }
    final bloomResult = bloomChain.first;
    // Dispose intermediates (skip first which is the result).
    for (int i = 1; i < bloomChain.length; i++) {
      bloomChain[i].dispose();
    }

    // Step 7: Tone map — composite scene + GI + bloom.
    final finalImage = await _runTonemap(
      sceneImage, giResult, bloomResult, resolution,
    );
    giResult.dispose();
    bloomResult.dispose();

    // Step 8: Readback luminance to engine every 8 frames.
    if (_frameCount % 8 == 0) {
      await _readbackLuminance(finalImage);
    }

    return finalImage;
  }

  // ---------------------------------------------------------------------------
  // Individual shader pass runners
  // ---------------------------------------------------------------------------

  Future<ui.Image> _runJFASeed(
    ui.Image occluder,
    Float64List resolution,
  ) async {
    final shader = _jfaSeedProg!.fragmentShader();
    shader.setFloat(0, resolution[0]);
    shader.setFloat(1, resolution[1]);
    shader.setImageSampler(0, occluder);
    return _renderShader(shader, _gridW, _gridH);
  }

  Future<ui.Image> _runJFAStep(
    ui.Image prevJFA,
    Float64List resolution,
    double stepSize,
  ) async {
    final shader = _jfaStepProg!.fragmentShader();
    shader.setFloat(0, resolution[0]);
    shader.setFloat(1, resolution[1]);
    shader.setFloat(2, stepSize);
    shader.setImageSampler(0, prevJFA);
    return _renderShader(shader, _gridW, _gridH);
  }

  Future<ui.Image> _runDistanceField(
    ui.Image jfa,
    ui.Image occluder,
    Float64List resolution,
  ) async {
    final shader = _distFieldProg!.fragmentShader();
    shader.setFloat(0, resolution[0]);
    shader.setFloat(1, resolution[1]);
    shader.setFloat(2, _maxDistance);
    shader.setImageSampler(0, jfa);
    shader.setImageSampler(1, occluder);
    return _renderShader(shader, _gridW, _gridH);
  }

  Future<ui.Image> _runRadianceCascade(
    ui.Image distField,
    ui.Image emitterMap,
    ui.Image prevCascade,
    Float64List resolution,
    double cascadeLevel,
    double maxCascades,
    double maxDistance,
  ) async {
    final shader = _radianceCascadeProg!.fragmentShader();
    shader.setFloat(0, resolution[0]);
    shader.setFloat(1, resolution[1]);
    shader.setFloat(2, cascadeLevel);
    shader.setFloat(3, maxCascades);
    shader.setFloat(4, maxDistance);
    shader.setImageSampler(0, distField);
    shader.setImageSampler(1, emitterMap);
    shader.setImageSampler(2, prevCascade);
    return _renderShader(shader, _gridW, _gridH);
  }

  Future<ui.Image> _runBloomDownsample(
    ui.Image source,
    double outW,
    double outH,
    double isFirstPass,
    double threshold,
  ) async {
    final shader = _bloomDownProg!.fragmentShader();
    shader.setFloat(0, outW);
    shader.setFloat(1, outH);
    shader.setFloat(2, 1.0 / source.width);
    shader.setFloat(3, 1.0 / source.height);
    shader.setFloat(4, threshold);
    shader.setFloat(5, isFirstPass);
    shader.setImageSampler(0, source);
    return _renderShader(shader, outW.ceil(), outH.ceil());
  }

  Future<ui.Image> _runBloomUpsample(
    ui.Image source,
    ui.Image destination,
    double outW,
    double outH,
    double srcTexelW,
    double srcTexelH,
    double intensity,
  ) async {
    final shader = _bloomUpProg!.fragmentShader();
    shader.setFloat(0, outW);
    shader.setFloat(1, outH);
    shader.setFloat(2, srcTexelW);
    shader.setFloat(3, srcTexelH);
    shader.setFloat(4, intensity);
    shader.setImageSampler(0, source);
    shader.setImageSampler(1, destination);
    return _renderShader(shader, outW.ceil(), outH.ceil());
  }

  Future<ui.Image> _runTonemap(
    ui.Image scene,
    ui.Image gi,
    ui.Image bloom,
    Float64List resolution,
  ) async {
    final shader = _tonemapProg!.fragmentShader();
    shader.setFloat(0, resolution[0]);
    shader.setFloat(1, resolution[1]);
    shader.setFloat(2, exposure);
    shader.setFloat(3, dayNightT);
    shader.setFloat(4, bloomStrength);
    shader.setFloat(5, giStrength);
    shader.setImageSampler(0, scene);
    shader.setImageSampler(1, gi);
    shader.setImageSampler(2, bloom);
    return _renderShader(shader, _gridW, _gridH);
  }

  // ---------------------------------------------------------------------------
  // Rendering helpers
  // ---------------------------------------------------------------------------

  /// Render a fragment shader to an offscreen image of the given dimensions.
  Future<ui.Image> _renderShader(
    ui.FragmentShader shader,
    int width,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..shader = shader;
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    shader.dispose();
    return image;
  }

  /// Create a 1x1 black image tiled to the given size (used as initial
  /// "previous cascade" input).
  Future<ui.Image> _createBlackImage(int width, int height) async {
    final pixels = Uint8List(width * height * 4); // All zeros = black transparent
    return _imageFromPixels(pixels, width, height);
  }

  /// Decode raw RGBA pixels into a [ui.Image].
  Future<ui.Image> _imageFromPixels(
    Uint8List pixels,
    int width,
    int height,
  ) {
    return _decodePixels(pixels, width, height);
  }

  Future<ui.Image> _decodePixels(
    Uint8List pixels,
    int width,
    int height,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    return frame.image;
  }

  // ---------------------------------------------------------------------------
  // Luminance readback
  // ---------------------------------------------------------------------------

  /// Read the final GI image back to CPU and update the engine's luminance
  /// array. This drives simulation features like photosynthesis and creature
  /// vision. Only called every 8 frames to amortize the GPU readback cost.
  Future<void> _readbackLuminance(ui.Image giImage) async {
    try {
      final byteData = await giImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return;

      final pixels = byteData.buffer.asUint8List();
      final lum = simulation.luminance;
      final total = _gridW * _gridH;

      for (int i = 0; i < total; i++) {
        final pi4 = i * 4;
        // Perceptual luminance: 0.2126R + 0.7152G + 0.0722B
        // Integer approximation: (54R + 183G + 18B) >> 8
        final r = pixels[pi4];
        final g = pixels[pi4 + 1];
        final b = pixels[pi4 + 2];
        lum[i] = ((54 * r + 183 * g + 18 * b) >> 8).clamp(0, 255);
      }
    } catch (_) {
      // Readback failure is non-fatal — luminance stays at previous values.
    }
  }
}

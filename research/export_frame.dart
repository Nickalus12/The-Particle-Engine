// ignore_for_file: avoid_print
/// Headless simulation frame exporter for Python test suite.
///
/// Runs the simulation for N frames, renders pixels, then writes:
///   - research/frame.rgba     Raw RGBA pixel buffer (320*180*4 bytes)
///   - research/grid.bin       Raw grid element IDs (320*180 bytes)
///   - research/frame_meta.json  Dimensions, frame count, element name map
///
/// Usage:
///   dart run research/export_frame.dart [frames] [config_path]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:the_particle_engine/simulation/simulation_engine.dart';
import 'package:the_particle_engine/simulation/element_registry.dart';
import 'package:the_particle_engine/simulation/element_behaviors.dart';
import 'package:the_particle_engine/simulation/pixel_renderer.dart';

void main(List<String> args) {
  final frames = args.isNotEmpty ? int.parse(args[0]) : 100;
  ElementRegistry.init();
  final configPath = _resolveTrialConfigPath(args);
  final engine = SimulationEngine(gridW: 320, gridH: 180, seed: 42);
  final trialConfig = configPath == null ? null : _loadTrialConfig(configPath);
  final overrideReport =
      trialConfig == null ? null : _applyTrialConfig(trialConfig);
  final renderer = PixelRenderer(engine);
  renderer.init();
  renderer.generateStars();

  _fillTestWorld(engine);

  for (int i = 0; i < frames; i++) {
    engine.step(simulateElement);
  }

  // Mark all chunks dirty so renderPixels produces a full frame
  engine.markAllDirty();
  renderer.renderPixels();

  File('research/frame.rgba').writeAsBytesSync(renderer.pixels);
  File('research/grid.bin').writeAsBytesSync(engine.grid);
  File('research/temp.bin').writeAsBytesSync(engine.temperature);
  File('research/velx.bin').writeAsBytesSync(
    Uint8List.view(engine.velX.buffer),
  );
  File('research/vely.bin').writeAsBytesSync(
    Uint8List.view(engine.velY.buffer),
  );
  File('research/life.bin').writeAsBytesSync(engine.life);
  File('research/flags.bin').writeAsBytesSync(engine.flags);

  final meta = <String, dynamic>{
    'contractVersion': 1,
    'manifest': trialConfig?['manifest'] ?? 'parameter_manifest.json',
    'pipeline': 'runtime_export',
    'scenarioId': 'foundation_sandbox_v1',
    'seed': 42,
    'width': 320,
    'height': 180,
    'frames': frames,
    'trialConfig': configPath == null
        ? null
        : <String, dynamic>{
            'path': configPath,
            'sourceLabel': trialConfig?['source_label'] ?? 'external',
            'applied': overrideReport!['applied'],
            'ignored': overrideReport['ignored'],
            'effectiveConfig': _buildEffectiveConfigSnapshot(trialConfig),
          },
    'elements': <String, int>{
      for (int i = 0; i < El.count; i++) elementNames[i]: i,
    },
  };
  File('research/frame_meta.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));

  print(
      'Exported: frame.rgba, grid.bin, temp.bin, velx.bin, vely.bin, life.bin, flags.bin');
}

String? _resolveTrialConfigPath(List<String> args) {
  if (args.length > 1 && args[1].trim().isNotEmpty) {
    return args[1];
  }

  final envPath = Platform.environment['TRIAL_CONFIG'];
  if (envPath != null && envPath.trim().isNotEmpty) {
    return envPath;
  }

  return null;
}

Map<String, dynamic> _loadTrialConfig(String configPath) {
  final raw = jsonDecode(File(configPath).readAsStringSync());
  if (raw is Map<String, dynamic>) {
    return raw;
  }
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  throw FormatException('Trial config must decode to a JSON object.');
}

Map<String, List<String>> _applyTrialConfig(Map<String, dynamic> config) {
  final applied = <String>{};
  final ignored = <String>{};

  final params = _asStringMap(config['params']);
  if (params != null) {
    _applyFlatParams(params, applied, ignored);
  } else if (!_looksStructured(config)) {
    _applyFlatParams(config, applied, ignored);
  }

  final elements = _asStringMap(config['elements']);
  if (elements != null) {
    _applyNestedElementOverrides(elements, applied, ignored);
  }

  final behavior = _asStringMap(config['behavior']);
  if (behavior != null) {
    for (final key in behavior.keys) {
      ignored.add('behavior.$key');
    }
  }

  final simTuning =
      _asStringMap(config['sim_tuning']) ?? _asStringMap(config['simTuning']);
  if (simTuning != null) {
    final overrides = <String, dynamic>{};
    simTuning.forEach((key, value) {
      if (value is num) {
        overrides[key] = value;
        applied.add('sim_tuning.$key');
      } else {
        ignored.add('sim_tuning.$key');
      }
    });
    SimTuning.applyOverrides(overrides);
  }

  return <String, List<String>>{
    'applied': applied.toList()..sort(),
    'ignored': ignored.toList()..sort(),
  };
}

bool _looksStructured(Map<String, dynamic> config) =>
    config.containsKey('params') ||
    config.containsKey('elements') ||
    config.containsKey('behavior') ||
    config.containsKey('sim_tuning') ||
    config.containsKey('simTuning');

Map<String, dynamic>? _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

int? _intValue(dynamic value) => value is num ? value.round() : null;

void _applyFlatParams(
  Map<String, dynamic> params,
  Set<String> applied,
  Set<String> ignored,
) {
  _applyElementOverride(
    'sand',
    El.sand,
    applied,
    density: _trackIntParam(params, 'sand_density', applied),
    gravity: _trackIntParam(params, 'sand_gravity', applied),
    meltPoint: _trackIntParam(params, 'sand_melt_point', applied),
  );
  _applyElementOverride(
    'water',
    El.water,
    applied,
    density: _trackIntParam(params, 'water_density', applied),
    gravity: _trackIntParam(params, 'water_gravity', applied),
    boilPoint: _trackIntParam(params, 'water_boil_point', applied),
    freezePoint: _trackIntParam(params, 'water_freeze_point', applied),
    surfaceTension: _trackIntParam(params, 'water_surface_tension', applied),
    reactivity: _trackIntParam(params, 'water_reactivity', applied),
  );
  _applyElementOverride(
    'oil',
    El.oil,
    applied,
    density: _trackIntParam(params, 'oil_density', applied),
    viscosity: _trackIntParam(params, 'oil_viscosity', applied),
    surfaceTension: _trackIntParam(params, 'oil_surface_tension', applied),
  );
  _applyElementOverride(
    'stone',
    El.stone,
    applied,
    density: _trackIntParam(params, 'stone_density', applied),
  );
  _applyElementOverride(
    'metal',
    El.metal,
    applied,
    density: _trackIntParam(params, 'metal_density', applied),
  );
  _applyElementOverride(
    'ice',
    El.ice,
    applied,
    density: _trackIntParam(params, 'ice_density', applied),
    meltPoint: _trackIntParam(params, 'ice_melt_point', applied),
  );
  _applyElementOverride(
    'wood',
    El.wood,
    applied,
    density: _trackIntParam(params, 'wood_density', applied),
  );
  _applyElementOverride(
    'dirt',
    El.dirt,
    applied,
    density: _trackIntParam(params, 'dirt_density', applied),
  );
  _applyElementOverride(
    'lava',
    El.lava,
    applied,
    density: _trackIntParam(params, 'lava_density', applied),
    viscosity: _trackIntParam(params, 'lava_viscosity', applied),
  );
  _applyElementOverride(
    'mud',
    El.mud,
    applied,
    viscosity: _trackIntParam(params, 'mud_viscosity', applied),
  );
  _applyElementOverride(
    'sodium',
    El.sodium,
    applied,
    reactivity: _trackIntParam(params, 'sodium_reactivity', applied),
  );
  _applyElementOverride(
    'potassium',
    El.potassium,
    applied,
    reactivity: _trackIntParam(params, 'potassium_reactivity', applied),
  );
  _applyElementOverride(
    'mercury',
    El.mercury,
    applied,
    density: _trackIntParam(params, 'mercury_density', applied),
    viscosity: _trackIntParam(params, 'mercury_viscosity', applied),
  );
  _applyElementOverride(
    'gold',
    El.gold,
    applied,
    density: _trackIntParam(params, 'gold_density', applied),
    meltPoint: _trackIntParam(params, 'gold_melt_point', applied),
  );
  _applyElementOverride(
    'fluorine',
    El.fluorine,
    applied,
    reactivity: _trackIntParam(params, 'fluorine_reactivity', applied),
  );
  _applyElementOverride(
    'chlorine',
    El.chlorine,
    applied,
    reactivity: _trackIntParam(params, 'chlorine_reactivity', applied),
  );

  final tuningAliases = <String, String>{
    'water_pressure_push': 'waterPressurePush',
    'water_hydraulic_rate': 'waterHydraulicRate',
    'fire_oxygen_consume': 'fireOxygenConsume',
    'dirt_water_erosion': 'dirtWaterErosionBase',
    'plant_acid_damage': 'plantAcidDamage',
    'threshold_pressure_erupt': 'thresholdPressureErupt',
  };
  final tuningOverrides = <String, dynamic>{};
  tuningAliases.forEach((sourceKey, targetKey) {
    final value = params[sourceKey];
    if (value is num) {
      tuningOverrides[targetKey] = value;
      applied.add(sourceKey);
    }
  });
  if (tuningOverrides.isNotEmpty) {
    SimTuning.applyOverrides(tuningOverrides);
  }

  final unsupportedFlatKeys = <String>{
    'evaporation_rate',
    'fire_spread_prob',
    'erosion_rate',
    'moisture_wicking_rate',
    'latent_heat_absorption',
    'chunk_collapse_chance',
    'uranium_heat_rate',
    'plutonium_heat_rate',
    'thorium_heat_rate',
    'phosphorus_ignition_chance',
    'ore_richness_mult',
  };
  for (final key in unsupportedFlatKeys) {
    if (params.containsKey(key) && !applied.contains(key)) {
      ignored.add(key);
    }
  }
}

void _applyNestedElementOverrides(
  Map<String, dynamic> elements,
  Set<String> applied,
  Set<String> ignored,
) {
  final elementIds = <String, int>{
    'sand': El.sand,
    'water': El.water,
    'oil': El.oil,
    'stone': El.stone,
    'metal': El.metal,
    'ice': El.ice,
    'wood': El.wood,
    'dirt': El.dirt,
    'lava': El.lava,
    'mud': El.mud,
    'sodium': El.sodium,
    'potassium': El.potassium,
    'mercury': El.mercury,
    'gold': El.gold,
    'fluorine': El.fluorine,
    'chlorine': El.chlorine,
  };

  elements.forEach((name, value) {
    final elementConfig = _asStringMap(value);
    final elementId = elementIds[name];
    if (elementConfig == null || elementId == null) {
      ignored.add('elements.$name');
      return;
    }

    final supportedKeys = <String>{};
    _applyElementOverride(
      name,
      elementId,
      applied,
      density: _trackNestedIntParam(
        elementConfig,
        name,
        'density',
        applied,
        supportedKeys,
      ),
      gravity: _trackNestedIntParam(
        elementConfig,
        name,
        'gravity',
        applied,
        supportedKeys,
      ),
      viscosity: _trackNestedIntParam(
        elementConfig,
        name,
        'viscosity',
        applied,
        supportedKeys,
      ),
      meltPoint: _trackNestedIntParam(
        elementConfig,
        name,
        'meltPoint',
        applied,
        supportedKeys,
      ),
      boilPoint: _trackNestedIntParam(
        elementConfig,
        name,
        'boilPoint',
        applied,
        supportedKeys,
      ),
      freezePoint: _trackNestedIntParam(
        elementConfig,
        name,
        'freezePoint',
        applied,
        supportedKeys,
      ),
      reductionPotential: _trackNestedIntParam(
        elementConfig,
        name,
        'reductionPotential',
        applied,
        supportedKeys,
      ),
      bondEnergy: _trackNestedIntParam(
        elementConfig,
        name,
        'bondEnergy',
        applied,
        supportedKeys,
      ),
      fuelValue: _trackNestedIntParam(
        elementConfig,
        name,
        'fuelValue',
        applied,
        supportedKeys,
      ),
      ignitionTemp: _trackNestedIntParam(
        elementConfig,
        name,
        'ignitionTemp',
        applied,
        supportedKeys,
      ),
      reactivity: _trackNestedIntParam(
        elementConfig,
        name,
        'reactivity',
        applied,
        supportedKeys,
      ),
      electronMobility: _trackNestedIntParam(
        elementConfig,
        name,
        'electronMobility',
        applied,
        supportedKeys,
      ),
      dielectric: _trackNestedIntParam(
        elementConfig,
        name,
        'dielectric',
        applied,
        supportedKeys,
      ),
    );

    for (final key in elementConfig.keys) {
      if (!supportedKeys.contains(key)) {
        ignored.add('elements.$name.$key');
      }
    }
  });
}

int? _trackIntParam(
  Map<String, dynamic> params,
  String key,
  Set<String> applied,
) {
  final value = _intValue(params[key]);
  if (value != null) {
    applied.add(key);
  }
  return value;
}

int? _trackNestedIntParam(
  Map<String, dynamic> params,
  String elementName,
  String key,
  Set<String> applied,
  Set<String> supportedKeys,
) {
  final value = _intValue(params[key]);
  if (value != null) {
    applied.add('elements.$elementName.$key');
    supportedKeys.add(key);
  }
  return value;
}

void _applyElementOverride(
  String name,
  int elementId,
  Set<String> applied, {
  int? density,
  int? gravity,
  int? viscosity,
  int? meltPoint,
  int? boilPoint,
  int? freezePoint,
  int? surfaceTension,
  int? reductionPotential,
  int? bondEnergy,
  int? fuelValue,
  int? ignitionTemp,
  int? reactivity,
  int? electronMobility,
  int? dielectric,
}) {
  final hasChange = density != null ||
      gravity != null ||
      viscosity != null ||
      meltPoint != null ||
      boilPoint != null ||
      freezePoint != null ||
      surfaceTension != null ||
      reductionPotential != null ||
      bondEnergy != null ||
      fuelValue != null ||
      ignitionTemp != null ||
      reactivity != null ||
      electronMobility != null ||
      dielectric != null;
  if (!hasChange) {
    return;
  }

  elementProperties[elementId] = elementProperties[elementId].copyWith(
    density: density,
    gravity: gravity,
    viscosity: viscosity,
    meltPoint: meltPoint,
    boilPoint: boilPoint,
    freezePoint: freezePoint,
    surfaceTension: surfaceTension,
    reductionPotential: reductionPotential,
    bondEnergy: bondEnergy,
    fuelValue: fuelValue,
    ignitionTemp: ignitionTemp,
    reactivity: reactivity,
    electronMobility: electronMobility,
    dielectric: dielectric,
  );

  if (density != null) {
    elementDensity[elementId] = density.clamp(0, 255);
  }
  if (gravity != null) {
    elementGravity[elementId] = gravity.clamp(-128, 127);
  }
  if (viscosity != null) {
    elementViscosity[elementId] = viscosity.clamp(0, 255);
  }
  if (surfaceTension != null) {
    elementSurfaceTension[elementId] = surfaceTension.clamp(0, 255);
  }
  if (reactivity != null) {
    elementReactivity[elementId] = reactivity.clamp(0, 255);
  }
  if (reductionPotential != null) {
    elementReductionPotential[elementId] =
        reductionPotential.clamp(-128, 127);
  }
  if (bondEnergy != null) {
    elementBondEnergy[elementId] = bondEnergy.clamp(0, 255);
  }
  if (fuelValue != null) {
    elementFuelValue[elementId] = fuelValue.clamp(0, 255);
  }
  if (ignitionTemp != null) {
    elementIgnitionTemp[elementId] = ignitionTemp.clamp(0, 255);
  }
  if (electronMobility != null) {
    elementElectronMobility[elementId] = electronMobility.clamp(0, 255);
  }
  if (dielectric != null) {
    elementDielectric[elementId] = dielectric.clamp(0, 255);
  }

  applied.add('element:$name');
}

Map<String, dynamic> _buildEffectiveConfigSnapshot(Map<String, dynamic>? config) {
  final trackedElements = <String, int>{
    'water': El.water,
    'sand': El.sand,
    'oil': El.oil,
    'wood': El.wood,
    'metal': El.metal,
    'acid': El.acid,
    'oxygen': El.oxygen,
    'fire': El.fire,
    'lava': El.lava,
    'charcoal': El.charcoal,
    'methane': El.methane,
    'salt': El.salt,
    'rust': El.rust,
  };

  return <String, dynamic>{
    'contractVersion': config?['contract_version'] ?? 1,
    'manifest': config?['manifest'] ?? 'parameter_manifest.json',
    'sourceLabel': config?['source_label'] ?? 'runtime_export',
    'elements': {
      for (final entry in trackedElements.entries)
        entry.key: _elementSnapshot(entry.value),
    },
    'simTuning': {
      'waterPressurePush': SimTuning.waterPressurePush,
      'waterHydraulicRate': SimTuning.waterHydraulicRate,
      'fireOxygenConsume': SimTuning.fireOxygenConsume,
      'dirtWaterErosionBase': SimTuning.dirtWaterErosionBase,
      'plantAcidDamage': SimTuning.plantAcidDamage,
      'thresholdPressureErupt': SimTuning.thresholdPressureErupt,
    },
  };
}

Map<String, dynamic> _elementSnapshot(int elementId) {
  final props = elementProperties[elementId];
  return <String, dynamic>{
    'density': props.density,
    'gravity': props.gravity,
    'viscosity': props.viscosity,
    'meltPoint': props.meltPoint,
    'boilPoint': props.boilPoint,
    'freezePoint': props.freezePoint,
    'surfaceTension': props.surfaceTension,
    'reductionPotential': props.reductionPotential,
    'bondEnergy': props.bondEnergy,
    'fuelValue': props.fuelValue,
    'ignitionTemp': props.ignitionTemp,
    'reactivity': props.reactivity,
    'electronMobility': props.electronMobility,
    'dielectric': props.dielectric,
  };
}

/// Populate grid with a representative test world (matches engine_benchmark).
void _fillTestWorld(SimulationEngine e) {
  final rng = Random(42);
  final w = e.gridW;
  final h = e.gridH;

  // Ground: stone base with dirt on top
  for (int x = 0; x < w; x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    for (int y = groundY; y < h; y++) {
      e.grid[y * w + x] = y < groundY + 3 ? El.dirt : El.stone;
    }
    if (rng.nextInt(20) == 0 && groundY > 10) {
      for (int ty = 1; ty <= 4; ty++) {
        if (groundY - ty >= 0) e.grid[(groundY - ty) * w + x] = El.wood;
      }
    }
  }

  // Water pool
  for (int y = (h * 0.5).round(); y < (h * 0.55).round(); y++) {
    for (int x = (w * 0.3).round(); x < (w * 0.5).round(); x++) {
      if (e.grid[y * w + x] == El.empty) {
        e.grid[y * w + x] = El.water;
        e.life[y * w + x] = 100;
      }
    }
  }

  // Lava pocket underground
  for (int y = (h * 0.8).round(); y < (h * 0.85).round(); y++) {
    for (int x = (w * 0.6).round(); x < (w * 0.7).round(); x++) {
      e.grid[y * w + x] = El.lava;
    }
  }

  // Sand
  for (int x = (w * 0.1).round(); x < (w * 0.25).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 2) {
      e.grid[(groundY - 1) * w + x] = El.sand;
      e.grid[(groundY - 2) * w + x] = El.sand;
    }
  }

  // Ice and snow
  for (int x = (w * 0.8).round(); x < (w * 0.9).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 2) {
      e.grid[(groundY - 1) * w + x] = El.snow;
      e.grid[(groundY - 2) * w + x] = El.ice;
    }
  }

  // Steam cluster (enough cells for visual tests)
  // Place a dense block that survives 100 frames despite condensation
  for (int sy = 8; sy < 14; sy++) {
    for (int sx = (w * 0.05).round(); sx < (w * 0.08).round(); sx++) {
      if (e.grid[sy * w + sx] == El.empty) {
        e.grid[sy * w + sx] = El.steam;
        e.temperature[sy * w + sx] = 200; // well above condensation point
      }
    }
  }

  // Metal beams
  for (int y = (h * 0.5).round(); y < (h * 0.55).round(); y++) {
    final x = (w * 0.55).round();
    e.grid[y * w + x] = El.metal;
  }

  // Oil layer on top of water pool (should float above water due to lower density)
  for (int y = (h * 0.48).round(); y < (h * 0.5).round(); y++) {
    for (int x = (w * 0.3).round(); x < (w * 0.35).round(); x++) {
      if (e.grid[y * w + x] == El.empty) {
        e.grid[y * w + x] = El.oil;
      }
    }
  }

  // Glass
  for (int x = (w * 0.5).round(); x < (w * 0.52).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 1) {
      e.grid[(groundY - 1) * w + x] = El.glass;
    }
  }

  // Plants on surface (grass type=1, stage=sprout=0 -> green)
  for (int x = (w * 0.35).round(); x < (w * 0.45).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 3) {
      for (int ty = 1; ty <= 3; ty++) {
        final py = groundY - ty;
        if (py >= 0) {
          final pidx = py * w + x;
          e.grid[pidx] = El.plant;
          // Set plant type=grass(1), stage=mature(2) -> deep green
          e.velX[pidx] = (2 << 4) | 1; // stage=mature, type=grass
          e.life[pidx] = 200; // plenty of moisture to survive
        }
      }
    }
  }

  // Cave pocket underground (empty cells below ground surface)
  for (int y = (h * 0.65).round(); y < (h * 0.72).round(); y++) {
    for (int x = (w * 0.15).round(); x < (w * 0.25).round(); x++) {
      e.grid[y * w + x] = El.empty;
    }
  }

  // Deep cave pocket (for proximity lighting gradient tests)
  for (int y = (h * 0.78).round(); y < (h * 0.85).round(); y++) {
    for (int x = (w * 0.35).round(); x < (w * 0.45).round(); x++) {
      e.grid[y * w + x] = El.empty;
    }
  }
  // Narrow tunnel connecting shallow cave area to deep cave (1 cell wide)
  for (int y = (h * 0.72).round(); y < (h * 0.78).round(); y++) {
    final tunnelX = (w * 0.25).round();
    e.grid[y * w + tunnelX] = El.empty;
  }
  // Underground water pool in deep cave (for moisture tint tests)
  for (int y = (h * 0.83).round(); y < (h * 0.85).round(); y++) {
    for (int x = (w * 0.38).round(); x < (w * 0.42).round(); x++) {
      e.grid[y * w + x] = El.water;
      e.life[y * w + x] = 100;
    }
  }

  // Mud patch
  for (int x = (w * 0.25).round(); x < (w * 0.3).round(); x++) {
    final groundY = (h * 0.55 + (10 * (0.5 + 0.5 * (x / w)))).round();
    if (groundY > 1) {
      e.grid[(groundY - 1) * w + x] = El.mud;
      e.grid[groundY * w + x] = El.mud;
    }
  }

  // Wood touching lava: lava heats wood -> auto-ignition -> persistent fire+smoke
  // Place wood layer directly above lava pocket (y=0.8 region)
  {
    final lavaTop = (h * 0.8).round();
    for (int x = (w * 0.6).round(); x < (w * 0.7).round(); x++) {
      // Wood layer just above lava (2 cells thick)
      for (int ty = 1; ty <= 2; ty++) {
        final wy = lavaTop - ty;
        if (wy >= 0) {
          final idx = wy * w + x;
          e.grid[idx] = El.wood;
          e.temperature[idx] = 200; // pre-heated by proximity to lava
        }
      }
    }
  }

  // Rainbow cell (decays to empty, placed high)
  {
    final rx = (w * 0.7).round();
    final ry = 5;
    e.grid[ry * w + rx] = El.rainbow;
  }

  e.markAllDirty();
}

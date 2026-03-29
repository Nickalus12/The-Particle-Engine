import '../simulation/element_registry.dart';
import 'ant.dart';

/// Species-level spawn rules used by colonies and investigative test lanes.
abstract class CreatureArchetype {
  const CreatureArchetype();

  String get key;
  int get maxPopulation;
  int get spawnFoodCost;
  bool canSpawnOnElement(int element);
}

class SpeciesSpawnProfile extends CreatureArchetype {
  const SpeciesSpawnProfile({
    required this.key,
    required this.maxPopulation,
    required this.spawnFoodCost,
    required this.allowedElements,
  });

  @override
  final String key;

  @override
  final int maxPopulation;

  @override
  final int spawnFoodCost;

  final Set<int> allowedElements;

  @override
  bool canSpawnOnElement(int element) => allowedElements.contains(element);
}

class SpeciesSpawnProfiles {
  static const SpeciesSpawnProfile ant = SpeciesSpawnProfile(
    key: 'ant',
    maxPopulation: 200,
    spawnFoodCost: 5,
    allowedElements: {El.empty, El.smoke, El.steam},
  );

  static const SpeciesSpawnProfile worm = SpeciesSpawnProfile(
    key: 'worm',
    maxPopulation: 60,
    spawnFoodCost: 3,
    allowedElements: {
      El.empty,
      El.smoke,
      El.steam,
      El.dirt,
      El.mud,
      El.compost,
    },
  );

  static const SpeciesSpawnProfile beetle = SpeciesSpawnProfile(
    key: 'beetle',
    maxPopulation: 60,
    spawnFoodCost: 3,
    allowedElements: {El.empty, El.smoke, El.steam, El.compost},
  );

  static const SpeciesSpawnProfile spider = SpeciesSpawnProfile(
    key: 'spider',
    maxPopulation: 50,
    spawnFoodCost: 3,
    allowedElements: {El.empty, El.smoke, El.steam},
  );

  static const SpeciesSpawnProfile fish = SpeciesSpawnProfile(
    key: 'fish',
    maxPopulation: 30,
    spawnFoodCost: 3,
    allowedElements: {El.water},
  );

  static const SpeciesSpawnProfile bee = SpeciesSpawnProfile(
    key: 'bee',
    maxPopulation: 50,
    spawnFoodCost: 3,
    allowedElements: {El.empty, El.smoke, El.steam},
  );

  static const SpeciesSpawnProfile firefly = SpeciesSpawnProfile(
    key: 'firefly',
    maxPopulation: 40,
    spawnFoodCost: 3,
    allowedElements: {El.empty, El.smoke, El.steam},
  );

  static SpeciesSpawnProfile forSpecies(CreatureSpecies species) {
    switch (species) {
      case CreatureSpecies.ant:
        return ant;
      case CreatureSpecies.worm:
        return worm;
      case CreatureSpecies.beetle:
        return beetle;
      case CreatureSpecies.spider:
        return spider;
      case CreatureSpecies.fish:
        return fish;
      case CreatureSpecies.bee:
        return bee;
      case CreatureSpecies.firefly:
        return firefly;
    }
  }
}

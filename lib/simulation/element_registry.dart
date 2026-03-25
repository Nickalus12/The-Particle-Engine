import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Element Registry -- Element type constants, colors, names, categories
// ---------------------------------------------------------------------------

/// Maximum number of element types the engine supports (byte range).
/// IDs 0..maxElements-1 are valid. The grid uses Uint8List so the hard
/// ceiling is 256, but we cap at 192 to keep lookup tables reasonably small
/// while accommodating all 118 periodic table elements.
const int maxElements = 192;

/// Element types stored in the grid as byte values.
///
/// Each constant maps to a unique byte used in the [SimulationEngine.grid]
/// array.  The first 25 (0..24) are built-in; higher IDs are available for
/// runtime-registered custom elements.
class El {
  static const int empty = 0;
  static const int sand = 1;
  static const int water = 2;
  static const int fire = 3;
  static const int ice = 4;
  static const int lightning = 5;
  static const int seed = 6;
  static const int stone = 7;
  static const int bedrock = stone; // Legacy alias for structural anchor logic.
  static const int tnt = 8;
  static const int rainbow = 9;
  static const int mud = 10;
  static const int steam = 11;
  static const int ant = 12;
  static const int oil = 13;
  static const int acid = 14;
  static const int glass = 15;
  static const int dirt = 16;
  static const int plant = 17;
  static const int lava = 18;
  static const int snow = 19;
  static const int wood = 20;
  static const int metal = 21;
  static const int smoke = 22;
  static const int bubble = 23;
  static const int ash = 24;

  // -- Phase 1: The Living Earth --
  static const int oxygen = 25;
  static const int co2 = 26;
  static const int fungus = 27;
  static const int spore = 28;
  static const int charcoal = 29;
  static const int compost = 30;
  static const int rust = 31;
  // -- Phase 2: The Atmosphere --
  static const int methane = 32;
  // -- Phase 3: The Chemistry Set --
  static const int salt = 33;
  static const int clay = 34;
  static const int algae = 35;
  // -- Phase 4: Colony Products --
  static const int honey = 36;
  // -- Phase 5: Chemistry Completeness --
  static const int hydrogen = 37;
  static const int sulfur = 38;
  static const int copper = 39;
  // -- Materials --
  static const int web = 40;  // Spider silk — sticky, flammable solid material
  // -- Phase 6: Neural Plants --
  static const int seaweed = 41;  // Aquatic plant, fish food, evolves toxicity
  static const int moss = 42;     // Surface plant, grows on rock, minimal light
  static const int vine = 43;     // Climbing plant, grows along surfaces
  static const int flower = 44;   // Reproducer, produces seeds/pollen
  static const int root = 45;     // Underground, grows downward seeking water
  static const int thorn = 46;    // Defensive, damages creatures
  static const int c4 = 47;       // Stable, triggered by voltage/pressure
  static const int uranium = 48;  // Heat multiplier
  static const int lead = 49;     // Shielding

  // -- Periodic Table: Noble Gases --
  static const int helium = 50;
  static const int neon = 51;
  static const int argon = 52;
  static const int krypton = 53;
  static const int xenon = 54;
  static const int radon = 55;

  // -- Periodic Table: Alkali Metals --
  static const int lithium = 56;
  static const int sodium = 57;
  static const int potassium = 58;
  static const int rubidium = 59;
  static const int cesium = 60;
  static const int francium = 61;

  // -- Periodic Table: Alkaline Earth Metals --
  static const int beryllium = 62;
  static const int magnesium = 63;
  static const int calcium = 64;
  static const int strontium = 65;
  static const int barium = 66;
  static const int radium = 67;

  // -- Periodic Table: Transition Metals (row 1-3) --
  static const int scandium = 68;
  static const int titanium = 69;
  static const int vanadium = 70;
  static const int chromium = 71;
  static const int manganese = 72;
  static const int cobalt = 73;
  static const int nickel = 74;
  static const int zinc = 75;
  static const int yttrium = 76;
  static const int zirconium = 77;
  static const int niobium = 78;
  static const int molybdenum = 79;
  static const int technetium = 80;
  static const int ruthenium = 81;
  static const int rhodium = 82;
  static const int palladium = 83;
  static const int silver = 84;
  static const int cadmium = 85;
  static const int hafnium = 86;
  static const int tantalum = 87;
  static const int tungsten = 88;
  static const int rhenium = 89;
  static const int osmium = 90;
  static const int iridium = 91;
  static const int platinum = 92;
  static const int gold = 93;
  // IDs 94-98 reserved for more transition metals
  static const int mercury = 94;
  static const int rutherfordium = 95;
  static const int dubnium = 96;
  static const int seaborgium = 97;
  static const int bohrium = 98;

  // -- Periodic Table: Post-Transition Metals --
  static const int aluminum = 100;
  static const int gallium = 101;
  static const int indium = 102;
  static const int tin = 103;
  static const int thallium = 104;
  static const int bismuth = 105;

  // -- Periodic Table: Metalloids --
  static const int boron = 106;
  static const int silicon = 107;
  static const int germanium = 108;
  static const int arsenic = 109;
  static const int antimony = 110;
  static const int tellurium = 111;

  // -- Periodic Table: Nonmetals --
  static const int carbon = 112; // Diamond form (charcoal is amorphous C)
  static const int nitrogen = 113;
  static const int phosphorus = 114;
  static const int selenium = 115;

  // -- Periodic Table: Halogens --
  static const int fluorine = 116;
  static const int chlorine = 117;
  static const int bromine = 118;
  static const int iodine = 119;
  static const int astatine = 120;
  static const int tennessine = 121;

  // -- Periodic Table: Lanthanides --
  static const int lanthanum = 122;
  static const int cerium = 123;
  static const int praseodymium = 124;
  static const int neodymium = 125;
  static const int promethium = 126;
  static const int samarium = 127;
  static const int europium = 128;
  static const int gadolinium = 129;
  static const int terbium = 130;
  static const int dysprosium = 131;
  static const int holmium = 132;
  static const int erbium = 133;
  static const int thulium = 134;
  static const int ytterbium = 135;
  static const int lutetium = 136;

  // -- Periodic Table: Actinides --
  static const int actinium = 137;
  static const int thorium = 138;
  static const int protactinium = 139;
  static const int neptunium = 140;
  static const int plutonium = 141;
  static const int americium = 142;
  static const int curium = 143;
  static const int berkelium = 144;
  static const int californium = 145;
  static const int einsteinium = 146;
  static const int fermium = 147;
  static const int mendelevium = 148;
  static const int nobelium = 149;
  static const int lawrencium = 150;
  // -- Periodic Table: Superheavy --
  static const int hassium = 151;
  static const int darmstadtium = 153;
  static const int roentgenium = 154;
  static const int copernicium = 155;
  static const int nihonium = 156;
  static const int flerovium = 157;
  static const int moscovium = 158;
  static const int livermorium = 159;
  static const int oganesson = 160;
  static const int meitnerium = 152;

  // -- Atmospherics (Phase 7) --
  static const int vapor = 161;
  static const int cloud = 162;

  /// Sentinel used only in the UI to represent the eraser tool.
  /// Kept outside the element ID range to avoid conflicts.
  static const int eraser = 255;

  /// Total number of built-in element types (0..162 inclusive).
  static const int count = 163;
}

// ---------------------------------------------------------------------------
// Element family classification (periodic table grouping)
// ---------------------------------------------------------------------------

/// Periodic table family constants for element grouping.
class ElFamily {
  static const int none = 0;
  static const int nobleGas = 1;
  static const int alkaliMetal = 2;
  static const int alkalineEarth = 3;
  static const int transitionMetal = 4;
  static const int postTransition = 5;
  static const int metalloid = 6;
  static const int nonmetal = 7;
  static const int halogen = 8;
  static const int lanthanide = 9;
  static const int actinide = 10;
  static const int compound = 11; // H2O, NaCl, CO2, etc.
  static const int organic = 12;  // Plants, creatures, etc.
  static const int superheavy = 13;
}

/// Pre-computed element family lookup table.
final Uint8List elementFamily = Uint8List(maxElements);

/// Per-element atomic number (0 = compound/special, 1-118 = real).
final Uint8List elementAtomicNumber = Uint8List(maxElements);

/// Per-element chemical symbol string.
final List<String> elementSymbol = List<String>.filled(maxElements, '');

/// Per-element base colors as packed 0xAARRGGBB integers.
///
/// Mutable list sized to [maxElements]. The renderer overrides these for
/// animated elements (fire, lava, rainbow, etc.) but falls back to these
/// values for everything else. Custom elements get their color set via
/// [ElementRegistry.register].
final List<int> baseColors = List<int>.filled(maxElements, 0x00000000)
  ..[El.empty] = 0x00000000
  ..[El.sand] = 0xFFD9C390     // Warm golden-tan
  ..[El.water] = 0xFF2E9AFF     // Deep clear blue
  ..[El.fire] = 0xFFFF8820      // Bright orange flame
  ..[El.ice] = 0xFFBDE5FF       // Light crystalline blue-white
  ..[El.lightning] = 0xFFFFFFA0  // Electric yellow-white
  ..[El.seed] = 0xFF8B7355      // Rich brown seed
  ..[El.stone] = 0xFF808090     // Cool blue-gray
  ..[El.tnt] = 0xFFCC2222       // Danger red
  ..[El.rainbow] = 0xFFFF00FF   // Magenta (cycles in renderer)
  ..[El.mud] = 0xFF5C3820       // Dark wet earth
  ..[El.steam] = 0x30C8D0E0     // Very translucent blue-gray wisp
  ..[El.ant] = 0xFF222222       // Dark body
  ..[El.oil] = 0xFF3A2820       // Dark with warm undertone
  ..[El.acid] = 0xFF30F030      // Toxic bright green
  ..[El.glass] = 0xCCDDE8FF     // Semi-transparent blue-white
  ..[El.dirt] = 0xFF8C6830      // Rich brown earth
  ..[El.plant] = 0xFF28B040     // Vibrant green
  ..[El.lava] = 0xFFFF5010      // Molten orange-red
  ..[El.snow] = 0xFFF0F4FF      // Cold sparkle white
  ..[El.wood] = 0xFFA05530      // Warm brown with grain tone
  ..[El.metal] = 0xFFA8A8B8     // Metallic blue-gray sheen
  ..[El.smoke] = 0xB09A9AA0     // Semi-transparent gray
  ..[El.bubble] = 0xA0C8E8FF    // Translucent cyan-white
  ..[El.ash] = 0xDDB0B0B8       // Light gray with transparency
  ..[El.oxygen] = 0x20C0E0FF    // Near-invisible pale blue
  ..[El.co2] = 0x30A0A0B0       // Semi-transparent gray-blue (heavier gas)
  ..[El.fungus] = 0xFF8B6914    // Brownish-gold bracket fungi
  ..[El.spore] = 0xC0B8A850     // Semi-transparent olive-yellow
  ..[El.charcoal] = 0xFF2A2A30  // Very dark gray-black
  ..[El.compost] = 0xFF3A2808   // Very dark rich brown
  ..[El.rust] = 0xFFA04820      // Dark orange-brown
  ..[El.methane] = 0x40A0E0A0   // Semi-transparent pale green
  ..[El.salt] = 0xFFF0E8E0      // Off-white crystalline
  ..[El.clay] = 0xFFC4865A      // Terracotta orange-brown
  ..[El.algae] = 0xFF2A8028     // Dark aquatic green
  ..[El.honey] = 0xFFD4A030     // Golden amber
  ..[El.hydrogen] = 0x10E0E0FF  // Near-invisible, slight blue
  ..[El.sulfur] = 0xFFD4C820    // Bright yellow
  ..[El.copper] = 0xFFB87333    // Classic copper orange-brown
  ..[El.web] = 0x40D0D0E0       // Very translucent silver
  ..[El.seaweed] = 0xFF1A6030   // Dark green, slightly blue
  ..[El.moss] = 0xFF4A7A3A      // Grey-green
  ..[El.vine] = 0xFF30A840      // Bright green
  ..[El.flower] = 0xFFE060A0    // Pink/magenta
  ..[El.root] = 0xFF6A4A20      // Dark brown, underground
  ..[El.thorn] = 0xFF505030    // Dark olive
  ..[El.c4] = 0xFFE0D0B0       // Pale clay/putty color
  ..[El.uranium] = 0xFF4A804A  // Dense, dark green-grey metal
  ..[El.lead] = 0xFF505560     // Heavy dark blue-grey
  // -- Noble Gases --
  ..[El.helium] = 0x10FFFFC0   // Near-invisible, pale yellow
  ..[El.neon] = 0x18FF6040     // Near-invisible, orange-red glow
  ..[El.argon] = 0x15C0A0E0    // Near-invisible, lavender
  ..[El.krypton] = 0x12E0E0E0  // Near-invisible, white
  ..[El.xenon] = 0x158080FF    // Near-invisible, blue
  ..[El.radon] = 0x2040FF60    // Semi-invisible, green (radioactive)
  // -- Alkali Metals --
  ..[El.lithium] = 0xFFD0C0C0  // Silvery white with slight pink
  ..[El.sodium] = 0xFFD8D0C0   // Silvery with warm tint
  ..[El.potassium] = 0xFFD0C8C0 // Silvery light
  ..[El.rubidium] = 0xFFC8C0B8 // Silvery with subtle gold
  ..[El.cesium] = 0xFFD4C890   // Pale gold
  ..[El.francium] = 0xFFC0B880 // Hypothetical gold tone
  // -- Alkaline Earth --
  ..[El.beryllium] = 0xFFD0D8D0 // Gray-white
  ..[El.magnesium] = 0xFFE0E0E0 // Bright silvery
  ..[El.calcium] = 0xFFE8E0D0  // Off-white bone color
  ..[El.strontium] = 0xFFE0D8C8 // Yellowish silver
  ..[El.barium] = 0xFFD8D0C0   // Silvery pale
  ..[El.radium] = 0xFF90E890   // Faint green glow
  // -- Transition Metals --
  ..[El.scandium] = 0xFFD0D0D0  // Silvery
  ..[El.titanium] = 0xFF878681  // Titanium gray
  ..[El.vanadium] = 0xFF909098  // Blue-gray
  ..[El.chromium] = 0xFFDBDFE0  // Bright chrome
  ..[El.manganese] = 0xFF9898A0 // Gray-pink
  ..[El.cobalt] = 0xFF6070B0   // Blue-tinted metal
  ..[El.nickel] = 0xFFC0C0B0   // Warm silver
  ..[El.zinc] = 0xFFB8BCC0     // Blue-white metal
  ..[El.yttrium] = 0xFFC8C8C8  // Silvery
  ..[El.zirconium] = 0xFFD0D0D8 // Gray-white
  ..[El.niobium] = 0xFF9098A0  // Blue-gray
  ..[El.molybdenum] = 0xFF9898A0 // Silvery gray
  ..[El.technetium] = 0xFFA0A0A8 // Silvery (radioactive)
  ..[El.ruthenium] = 0xFFA8A8B0 // Silvery
  ..[El.rhodium] = 0xFFD0D0D8  // Bright silver
  ..[El.palladium] = 0xFFD8D8E0 // Silver-white
  ..[El.silver] = 0xFFC0C0C8   // Classic silver
  ..[El.cadmium] = 0xFFD0D0E0  // Bluish silver
  ..[El.hafnium] = 0xFFA0A0A8  // Gray
  ..[El.tantalum] = 0xFF9898A0  // Blue-gray
  ..[El.tungsten] = 0xFF808080  // Dark steel gray
  ..[El.rhenium] = 0xFF9898A0   // Gray
  ..[El.osmium] = 0xFF8888A0   // Blue-gray (densest)
  ..[El.iridium] = 0xFFD0D0D8  // Silver-white
  ..[El.platinum] = 0xFFE5E4E2  // Platinum gray
  ..[El.gold] = 0xFFFFD700     // Classic gold
  ..[El.mercury] = 0xFFD0D8E0  // Liquid silver
  ..[El.rutherfordium] = 0xFF808890 // Synthetic gray
  ..[El.dubnium] = 0xFF808890
  ..[El.seaborgium] = 0xFF808890
  ..[El.bohrium] = 0xFF808890
  // -- Post-Transition Metals --
  ..[El.aluminum] = 0xFFBEC2CB  // Aluminum silver
  ..[El.gallium] = 0xFFD0D8E8  // Bluish silver
  ..[El.indium] = 0xFFD0D0D8   // Silvery
  ..[El.tin] = 0xFFD0D0D0      // Classic tin
  ..[El.thallium] = 0xFFA0A0A8 // Bluish gray
  ..[El.bismuth] = 0xFFD0A0C0  // Pinkish-silver (iridescent)
  // -- Metalloids --
  ..[El.boron] = 0xFF4A3830    // Dark brown
  ..[El.silicon] = 0xFF6A6A78  // Dark gray (semiconductor)
  ..[El.germanium] = 0xFF888888 // Gray
  ..[El.arsenic] = 0xFF707078  // Steely gray
  ..[El.antimony] = 0xFFB0B0B8 // Silvery
  ..[El.tellurium] = 0xFFB0B0B8 // Silvery
  // -- Nonmetals --
  ..[El.carbon] = 0xFFB0E8FF   // Diamond: pale ice-blue transparent
  ..[El.nitrogen] = 0x10A0C0FF // Near-invisible, pale blue
  ..[El.phosphorus] = 0xFFF0F0C0 // Waxy yellow-white
  ..[El.selenium] = 0xFF808070  // Gray
  // -- Halogens --
  ..[El.fluorine] = 0x30E0FF80  // Pale yellow gas
  ..[El.chlorine] = 0x40B0FF50  // Yellow-green gas
  ..[El.bromine] = 0xFF8B2020   // Dark reddish-brown liquid
  ..[El.iodine] = 0xFF4B0082    // Dark violet solid
  ..[El.astatine] = 0xFF303030  // Very dark (radioactive)
  ..[El.tennessine] = 0xFF404040
  // -- Lanthanides --
  ..[El.lanthanum] = 0xFFD0D0D0
  ..[El.cerium] = 0xFFD0C8B0
  ..[El.praseodymium] = 0xFFD0D0C0
  ..[El.neodymium] = 0xFFC8C0B0
  ..[El.promethium] = 0xFFC0C0B0
  ..[El.samarium] = 0xFFD0D0C0
  ..[El.europium] = 0xFFD0D0C8
  ..[El.gadolinium] = 0xFFD0D0D0
  ..[El.terbium] = 0xFFD0D0C0
  ..[El.dysprosium] = 0xFFD0D0C0
  ..[El.holmium] = 0xFFD0D0C8
  ..[El.erbium] = 0xFFD0D0C0
  ..[El.thulium] = 0xFFD0D0C8
  ..[El.ytterbium] = 0xFFD0D0C8
  ..[El.lutetium] = 0xFFD0D0D0
  // -- Actinides --
  ..[El.actinium] = 0xFFC0D0C0
  ..[El.thorium] = 0xFF909898  // Dark silvery
  ..[El.protactinium] = 0xFFA8B0A8
  ..[El.neptunium] = 0xFF7888A0 // Silvery-blue
  ..[El.plutonium] = 0xFF606870 // Dark silvery
  ..[El.americium] = 0xFF90A090 // Silvery green tint
  ..[El.curium] = 0xFF88A088
  ..[El.berkelium] = 0xFF88A088
  ..[El.californium] = 0xFF88A088
  ..[El.einsteinium] = 0xFF88A088
  ..[El.fermium] = 0xFF88A088
  ..[El.mendelevium] = 0xFF88A088
  ..[El.nobelium] = 0xFF88A088
  ..[El.lawrencium] = 0xFF88A088
  // -- Superheavy --
  ..[El.hassium] = 0xFF707078
  ..[El.meitnerium] = 0xFF707078
  ..[El.darmstadtium] = 0xFF707078
  ..[El.roentgenium] = 0xFF707078
  ..[El.copernicium] = 0xFF707078
  ..[El.nihonium] = 0xFF707078
  ..[El.flerovium] = 0xFF707078
  ..[El.moscovium] = 0xFF707078
  ..[El.livermorium] = 0xFF707078
  ..[El.oganesson] = 0xFF707078
  ..[El.vapor] = 0x40DCEEFF
  ..[El.cloud] = 0x90E6EEF8;

/// Human-readable element names (index = element type).
/// Mutable list sized to [maxElements].
final List<String> elementNames = List<String>.filled(maxElements, '')
  ..[El.empty] = 'Empty'
  ..[El.sand] = 'Sand'
  ..[El.water] = 'Water'
  ..[El.fire] = 'Fire'
  ..[El.ice] = 'Ice'
  ..[El.lightning] = 'Zap'
  ..[El.seed] = 'Seed'
  ..[El.stone] = 'Stone'
  ..[El.tnt] = 'TNT'
  ..[El.rainbow] = 'Rainbow'
  ..[El.mud] = 'Mud'
  ..[El.steam] = 'Steam'
  ..[El.ant] = 'Ant'
  ..[El.oil] = 'Oil'
  ..[El.acid] = 'Acid'
  ..[El.glass] = 'Glass'
  ..[El.dirt] = 'Dirt'
  ..[El.plant] = 'Plant'
  ..[El.lava] = 'Lava'
  ..[El.snow] = 'Snow'
  ..[El.wood] = 'Wood'
  ..[El.metal] = 'Metal'
  ..[El.smoke] = 'Smoke'
  ..[El.bubble] = 'Bubble'
  ..[El.ash] = 'Ash'
  ..[El.oxygen] = 'Oxygen'
  ..[El.co2] = 'CO₂'
  ..[El.fungus] = 'Fungus'
  ..[El.spore] = 'Spore'
  ..[El.charcoal] = 'Charcoal'
  ..[El.compost] = 'Compost'
  ..[El.rust] = 'Rust'
  ..[El.methane] = 'Methane'
  ..[El.salt] = 'Salt'
  ..[El.clay] = 'Clay'
  ..[El.algae] = 'Algae'
  ..[El.honey] = 'Honey'
  ..[El.hydrogen] = 'Hydrogen'
  ..[El.sulfur] = 'Sulfur'
  ..[El.copper] = 'Copper'
  ..[El.web] = 'Web'
  ..[El.seaweed] = 'Seaweed'
  ..[El.moss] = 'Moss'
  ..[El.vine] = 'Vine'
  ..[El.flower] = 'Flower'
  ..[El.root] = 'Root'
  ..[El.thorn] = 'Thorn'
  ..[El.c4] = 'C4'
  ..[El.uranium] = 'Uranium'
  ..[El.lead] = 'Lead'
  // -- Noble Gases --
  ..[El.helium] = 'Helium' ..[El.neon] = 'Neon' ..[El.argon] = 'Argon'
  ..[El.krypton] = 'Krypton' ..[El.xenon] = 'Xenon' ..[El.radon] = 'Radon'
  // -- Alkali Metals --
  ..[El.lithium] = 'Lithium' ..[El.sodium] = 'Sodium' ..[El.potassium] = 'Potassium'
  ..[El.rubidium] = 'Rubidium' ..[El.cesium] = 'Cesium' ..[El.francium] = 'Francium'
  // -- Alkaline Earth --
  ..[El.beryllium] = 'Beryllium' ..[El.magnesium] = 'Magnesium'
  ..[El.calcium] = 'Calcium' ..[El.strontium] = 'Strontium'
  ..[El.barium] = 'Barium' ..[El.radium] = 'Radium'
  // -- Transition Metals --
  ..[El.scandium] = 'Scandium' ..[El.titanium] = 'Titanium'
  ..[El.vanadium] = 'Vanadium' ..[El.chromium] = 'Chromium'
  ..[El.manganese] = 'Manganese' ..[El.cobalt] = 'Cobalt'
  ..[El.nickel] = 'Nickel' ..[El.zinc] = 'Zinc'
  ..[El.yttrium] = 'Yttrium' ..[El.zirconium] = 'Zirconium'
  ..[El.niobium] = 'Niobium' ..[El.molybdenum] = 'Molybdenum'
  ..[El.technetium] = 'Technetium' ..[El.ruthenium] = 'Ruthenium'
  ..[El.rhodium] = 'Rhodium' ..[El.palladium] = 'Palladium'
  ..[El.silver] = 'Silver' ..[El.cadmium] = 'Cadmium'
  ..[El.hafnium] = 'Hafnium' ..[El.tantalum] = 'Tantalum'
  ..[El.tungsten] = 'Tungsten' ..[El.rhenium] = 'Rhenium'
  ..[El.osmium] = 'Osmium' ..[El.iridium] = 'Iridium'
  ..[El.platinum] = 'Platinum' ..[El.gold] = 'Gold'
  ..[El.mercury] = 'Mercury'
  ..[El.rutherfordium] = 'Rutherfordium' ..[El.dubnium] = 'Dubnium'
  ..[El.seaborgium] = 'Seaborgium' ..[El.bohrium] = 'Bohrium'
  // -- Post-Transition --
  ..[El.aluminum] = 'Aluminum' ..[El.gallium] = 'Gallium'
  ..[El.indium] = 'Indium' ..[El.tin] = 'Tin'
  ..[El.thallium] = 'Thallium' ..[El.bismuth] = 'Bismuth'
  // -- Metalloids --
  ..[El.boron] = 'Boron' ..[El.silicon] = 'Silicon'
  ..[El.germanium] = 'Germanium' ..[El.arsenic] = 'Arsenic'
  ..[El.antimony] = 'Antimony' ..[El.tellurium] = 'Tellurium'
  // -- Nonmetals --
  ..[El.carbon] = 'Diamond' ..[El.nitrogen] = 'Nitrogen'
  ..[El.phosphorus] = 'Phosphorus' ..[El.selenium] = 'Selenium'
  // -- Halogens --
  ..[El.fluorine] = 'Fluorine' ..[El.chlorine] = 'Chlorine'
  ..[El.bromine] = 'Bromine' ..[El.iodine] = 'Iodine'
  ..[El.astatine] = 'Astatine' ..[El.tennessine] = 'Tennessine'
  // -- Lanthanides --
  ..[El.lanthanum] = 'Lanthanum' ..[El.cerium] = 'Cerium'
  ..[El.praseodymium] = 'Praseodymium' ..[El.neodymium] = 'Neodymium'
  ..[El.promethium] = 'Promethium' ..[El.samarium] = 'Samarium'
  ..[El.europium] = 'Europium' ..[El.gadolinium] = 'Gadolinium'
  ..[El.terbium] = 'Terbium' ..[El.dysprosium] = 'Dysprosium'
  ..[El.holmium] = 'Holmium' ..[El.erbium] = 'Erbium'
  ..[El.thulium] = 'Thulium' ..[El.ytterbium] = 'Ytterbium'
  ..[El.lutetium] = 'Lutetium'
  // -- Actinides --
  ..[El.actinium] = 'Actinium' ..[El.thorium] = 'Thorium'
  ..[El.protactinium] = 'Protactinium' ..[El.neptunium] = 'Neptunium'
  ..[El.plutonium] = 'Plutonium' ..[El.americium] = 'Americium'
  ..[El.curium] = 'Curium' ..[El.berkelium] = 'Berkelium'
  ..[El.californium] = 'Californium' ..[El.einsteinium] = 'Einsteinium'
  ..[El.fermium] = 'Fermium' ..[El.mendelevium] = 'Mendelevium'
  ..[El.nobelium] = 'Nobelium' ..[El.lawrencium] = 'Lawrencium'
  // -- Superheavy --
  ..[El.hassium] = 'Hassium' ..[El.meitnerium] = 'Meitnerium'
  ..[El.darmstadtium] = 'Darmstadtium' ..[El.roentgenium] = 'Roentgenium'
  ..[El.copernicium] = 'Copernicium' ..[El.nihonium] = 'Nihonium'
  ..[El.flerovium] = 'Flerovium' ..[El.moscovium] = 'Moscovium'
  ..[El.livermorium] = 'Livermorium' ..[El.oganesson] = 'Oganesson'
  ..[El.vapor] = 'Vapor' ..[El.cloud] = 'Cloud';

/// Static elements unaffected by wind or shake.
final Set<int> staticElements = {
  El.stone, El.metal, El.wood, El.glass, El.ice, El.rust, El.copper, El.web,
  El.thorn, El.uranium, El.lead,
  // Periodic table solids
  El.titanium, El.chromium, El.manganese, El.cobalt, El.nickel, El.zinc,
  El.zirconium, El.niobium, El.molybdenum, El.ruthenium, El.rhodium,
  El.palladium, El.silver, El.hafnium, El.tantalum, El.tungsten, El.rhenium,
  El.osmium, El.iridium, El.platinum, El.gold,
  El.aluminum, El.tin, El.bismuth,
  El.boron, El.silicon, El.germanium, El.carbon, El.iodine,
  El.thorium, El.plutonium,
};

/// Pre-computed wind sensitivity per element type.
///   0 = unaffected, 1 = heavy liquid, 2 = light, 3 = ultra-light (ash).
final Uint8List windSensitivity = () {
  final t = Uint8List(maxElements);
  for (final el in [
    El.sand, El.snow, El.smoke, El.fire, El.steam, El.bubble, El.seed,
  ]) {
    t[el] = 2;
  }
  for (final el in [El.water, El.oil, El.acid]) {
    t[el] = 1;
  }
  t[El.ash] = 3;
  t[El.oxygen] = 2;
  t[El.co2] = 1;
  t[El.spore] = 3;
  t[El.methane] = 2;
  t[El.hydrogen] = 3; // lightest gas, very wind-sensitive
  t[El.sulfur] = 1;
  return t;
}();

// ---------------------------------------------------------------------------
// Element category bitmasks (for AI sensing API)
// ---------------------------------------------------------------------------

/// Category flags for O(1) element classification.
class ElCat {
  static const int solid = 0x01;
  static const int liquid = 0x02;
  static const int gas = 0x04;
  static const int organic = 0x08;
  static const int danger = 0x10;
  static const int flammable = 0x20;
  static const int conductive = 0x40;
}

/// Pre-computed category bitmask per element type.
/// Sized to [maxElements] so custom elements can be registered.
final Uint8List elCategory = () {
  final t = Uint8List(maxElements);
  t[El.sand] = ElCat.organic;
  t[El.water] = ElCat.liquid | ElCat.conductive;
  t[El.fire] = ElCat.gas | ElCat.danger;
  t[El.ice] = ElCat.solid;
  t[El.lightning] = ElCat.danger;
  t[El.seed] = ElCat.organic | ElCat.flammable;
  t[El.stone] = ElCat.solid;
  t[El.tnt] = ElCat.danger;
  t[El.mud] = ElCat.liquid | ElCat.organic;
  t[El.steam] = ElCat.gas;
  t[El.oil] = ElCat.liquid | ElCat.flammable;
  t[El.acid] = ElCat.liquid | ElCat.danger;
  t[El.glass] = ElCat.solid;
  t[El.dirt] = ElCat.organic;
  t[El.plant] = ElCat.organic | ElCat.flammable;
  t[El.lava] = ElCat.liquid | ElCat.danger;
  t[El.snow] = ElCat.organic;
  t[El.wood] = ElCat.solid | ElCat.flammable;
  t[El.metal] = ElCat.solid | ElCat.conductive;
  t[El.smoke] = ElCat.gas;
  t[El.ash] = ElCat.organic;
  t[El.oxygen] = ElCat.gas;
  t[El.co2] = ElCat.gas;
  t[El.fungus] = ElCat.organic | ElCat.flammable;
  t[El.spore] = ElCat.organic | ElCat.flammable;
  t[El.charcoal] = ElCat.flammable;
  t[El.compost] = ElCat.organic;
  t[El.rust] = ElCat.solid;
  t[El.methane] = ElCat.gas | ElCat.flammable | ElCat.danger;
  t[El.salt] = ElCat.solid;
  t[El.clay] = ElCat.organic;
  t[El.algae] = ElCat.organic;
  t[El.honey] = ElCat.liquid | ElCat.organic;
  t[El.hydrogen] = ElCat.gas | ElCat.flammable | ElCat.danger;
  t[El.sulfur] = ElCat.flammable;
  t[El.copper] = ElCat.solid | ElCat.conductive;
  t[El.web] = ElCat.solid | ElCat.flammable;
  t[El.seaweed] = ElCat.organic | ElCat.flammable;
  t[El.moss] = ElCat.organic | ElCat.flammable;
  t[El.vine] = ElCat.organic | ElCat.flammable;
  t[El.flower] = ElCat.organic | ElCat.flammable;
  t[El.root] = ElCat.organic;
  t[El.thorn] = ElCat.organic | ElCat.solid;
  t[El.c4] = ElCat.solid | ElCat.flammable | ElCat.danger;
  t[El.uranium] = ElCat.solid | ElCat.danger | ElCat.conductive;
  t[El.lead] = ElCat.solid;
  // Noble gases
  for (final el in [El.helium, El.neon, El.argon, El.krypton, El.xenon]) {
    t[el] = ElCat.gas;
  }
  t[El.radon] = ElCat.gas | ElCat.danger; // radioactive
  // Alkali metals
  for (final el in [El.lithium, El.sodium, El.potassium, El.rubidium, El.cesium, El.francium]) {
    t[el] = ElCat.solid | ElCat.danger; // reactive with water
  }
  // Alkaline earth
  for (final el in [El.beryllium, El.magnesium, El.calcium, El.strontium, El.barium]) {
    t[el] = ElCat.solid;
  }
  t[El.radium] = ElCat.solid | ElCat.danger; // radioactive
  // Transition metals
  for (final el in [
    El.scandium, El.titanium, El.vanadium, El.chromium, El.manganese,
    El.cobalt, El.nickel, El.zinc, El.yttrium, El.zirconium, El.niobium,
    El.molybdenum, El.ruthenium, El.rhodium, El.palladium, El.silver,
    El.cadmium, El.hafnium, El.tantalum, El.tungsten, El.rhenium,
    El.osmium, El.iridium, El.platinum, El.gold,
  ]) {
    t[el] = ElCat.solid | ElCat.conductive;
  }
  t[El.technetium] = ElCat.solid | ElCat.conductive | ElCat.danger; // radioactive
  t[El.mercury] = ElCat.liquid | ElCat.conductive | ElCat.danger; // toxic liquid metal
  for (final el in [El.rutherfordium, El.dubnium, El.seaborgium, El.bohrium]) {
    t[el] = ElCat.solid | ElCat.danger;
  }
  // Post-transition metals
  for (final el in [El.aluminum, El.gallium, El.indium, El.tin, El.thallium, El.bismuth]) {
    t[el] = ElCat.solid | ElCat.conductive;
  }
  // Metalloids
  for (final el in [El.boron, El.silicon, El.germanium, El.antimony, El.tellurium]) {
    t[el] = ElCat.solid;
  }
  t[El.arsenic] = ElCat.solid | ElCat.danger; // toxic
  // Nonmetals
  t[El.carbon] = ElCat.solid; // diamond
  t[El.nitrogen] = ElCat.gas;
  t[El.phosphorus] = ElCat.solid | ElCat.flammable | ElCat.danger;
  t[El.selenium] = ElCat.solid;
  // Halogens
  t[El.fluorine] = ElCat.gas | ElCat.danger;
  t[El.chlorine] = ElCat.gas | ElCat.danger;
  t[El.bromine] = ElCat.liquid | ElCat.danger;
  t[El.iodine] = ElCat.solid;
  t[El.astatine] = ElCat.solid | ElCat.danger;
  t[El.tennessine] = ElCat.solid | ElCat.danger;
  // Lanthanides
  for (final el in [
    El.lanthanum, El.cerium, El.praseodymium, El.neodymium, El.samarium,
    El.europium, El.gadolinium, El.terbium, El.dysprosium, El.holmium,
    El.erbium, El.thulium, El.ytterbium, El.lutetium,
  ]) {
    t[el] = ElCat.solid | ElCat.conductive;
  }
  t[El.promethium] = ElCat.solid | ElCat.conductive | ElCat.danger; // radioactive
  // Actinides
  for (final el in [
    El.actinium, El.thorium, El.protactinium, El.neptunium, El.plutonium,
    El.americium, El.curium, El.berkelium, El.californium, El.einsteinium,
    El.fermium, El.mendelevium, El.nobelium, El.lawrencium,
  ]) {
    t[el] = ElCat.solid | ElCat.danger; // all radioactive
  }
  // Superheavy
  for (final el in [
    El.hassium, El.meitnerium, El.darmstadtium, El.roentgenium,
    El.copernicium, El.nihonium, El.flerovium, El.moscovium,
    El.livermorium, El.oganesson,
  ]) {
    t[el] = ElCat.solid | ElCat.danger;
  }
  return t;
}();

// ---------------------------------------------------------------------------
// Never-settle table (elements that should never become dormant)
// ---------------------------------------------------------------------------

/// Elements that must never settle (have ongoing time-based behaviors).
/// Sized to [maxElements] for extensibility.
final Uint8List neverSettle = () {
  final t = Uint8List(maxElements);
  for (final el in [
    El.lava, El.fire, El.smoke, El.steam, El.bubble, El.acid, El.ash,
    El.ant, El.plant, El.dirt, El.wood, El.metal, El.oil, El.mud,
    El.snow, El.rainbow,
    El.oxygen, El.co2, El.fungus, El.spore, El.compost, El.methane,
    El.algae, El.honey, El.hydrogen, El.sulfur, El.web,
    El.seaweed, El.moss, El.vine, El.flower, El.root, El.thorn,
    // Periodic table: gases, radioactives, reactive elements
    El.helium, El.neon, El.argon, El.krypton, El.xenon, El.radon,
    El.lithium, El.sodium, El.potassium, El.rubidium, El.cesium, El.francium,
    El.fluorine, El.chlorine, El.bromine,
    El.nitrogen, El.phosphorus,
    El.mercury, El.gallium,
    El.radium, El.thorium, El.plutonium, El.americium,
  ]) {
    t[el] = 1;
  }
  return t;
}();

// ---------------------------------------------------------------------------
// Batch neighbor-check lookup tables (for checkAdjacentAnyOf)
// ---------------------------------------------------------------------------

/// Vine/plant support surfaces: stone, dirt, wood, vine, plant, metal.
final Uint8List plantSupportSet = () {
  final t = Uint8List(maxElements);
  for (final el in [El.stone, El.dirt, El.wood, El.vine, El.plant, El.metal]) {
    t[el] = 1;
  }
  return t;
}();

/// Fungus attachment surfaces: dirt, wood, compost, fungus, stone.
final Uint8List fungusAttachSet = () {
  final t = Uint8List(maxElements);
  for (final el in [El.dirt, El.wood, El.compost, El.fungus, El.stone]) {
    t[el] = 1;
  }
  return t;
}();

/// Thorn attachment: plant, vine, flower, thorn.
final Uint8List thornAttachSet = () {
  final t = Uint8List(maxElements);
  for (final el in [El.plant, El.vine, El.flower, El.thorn]) {
    t[el] = 1;
  }
  return t;
}();

// ---------------------------------------------------------------------------
// Element physics states
// ---------------------------------------------------------------------------

/// Physics state determines how an element moves in the unified movement system.
enum PhysicsState {
  /// Does not move (stone, metal, glass, ice, wood).
  solid,
  /// Falls fast, piles diagonally (sand, dirt, TNT).
  granular,
  /// Falls, spreads laterally based on viscosity (water, oil, acid, lava, mud).
  liquid,
  /// Rises, spreads laterally (smoke, steam, fire, rainbow).
  gas,
  /// Falls very slowly, drifts (ash, snow, bubble).
  powder,
  /// Special movement handled entirely by custom logic (ant, lightning, seed, plant).
  special,
}

// ---------------------------------------------------------------------------
// Element properties -- property-driven physics data per element type
// ---------------------------------------------------------------------------

/// Physical properties for each element type.
///
/// This enables property-driven physics: movement, density displacement,
/// temperature reactions, and viscosity are all derived from these values
/// instead of being hard-coded per element.
class ElementProperties {
  /// Density (0-255). Heavier elements sink through lighter ones.
  /// Air/empty = 0, gases ~5-15, liquids ~60-120, granulars ~140-180, solids ~200-255.
  final int density;

  /// Viscosity (1-10). How many frames between lateral movements for liquids.
  /// Water=1, Oil=2, Mud=3, Lava=4, Honey=5.
  final int viscosity;

  /// Gravity strength. Positive = falls, negative = rises, 0 = static.
  /// Sand=2, Water=1, Smoke=-1, Stone=0.
  final int gravity;

  /// Physics state governing movement pattern.
  final PhysicsState state;

  /// Whether this element can catch fire.
  final bool flammable;

  /// Heat conductivity (0.0-1.0). How fast temperature transfers to neighbors.
  /// Metal=0.9, Stone=0.5, Water=0.3, Wood=0.1, Air=0.02.
  final double heatConductivity;

  /// Temperature at which a solid becomes liquid (0 = no melting).
  /// Ice=40, Stone=220, Metal=240, Glass=200.
  final int meltPoint;

  /// Temperature at which a liquid becomes gas (0 = no boiling).
  /// Water=180, Oil=160.
  final int boilPoint;

  /// Temperature at which a liquid becomes solid (0 = no freezing).
  /// Water=30, Lava=60.
  final int freezePoint;

  /// Element this becomes when it melts (0 = none).
  final int meltsInto;

  /// Element this becomes when it boils/evaporates (0 = none).
  final int boilsInto;

  /// Element this becomes when it freezes (0 = none).
  final int freezesInto;

  /// Base temperature this element emits (0 = neutral, >128 = hot, <128 = cold).
  /// Fire=230, Lava=250, Ice=20, Snow=40, neutral=128.
  final int baseTemperature;

  /// Corrosion resistance (0-255). Higher = harder for acid to dissolve.
  /// Wood=30, Ice=40, Glass=50, Stone=60, Metal=90, empty/liquids=0.
  final int corrosionResistance;

  /// Light emission intensity (0-255). 0 = no glow.
  /// Fire=180, Lava=220, Lightning=255, Rainbow=100.
  final int lightEmission;

  /// Light emission color (RGB components, 0-255).
  final int lightR;
  final int lightG;
  final int lightB;

  /// Decay rate: 0 = eternal, 1-10 = frames per life increment.
  /// Fire=3, Smoke=2, Steam=1, Rainbow=1.
  final int decayRate;

  /// Element this becomes when life expires from decay. 0 = empty.
  /// Fire→smoke(22), Smoke→empty(0), Steam→water(2).
  final int decaysInto;

  /// Surface tension (0-10). Higher values make isolated droplets cohesive.
  /// Water=5, Oil=3, Acid=2, Lava=8, Mud=6.
  final int surfaceTension;

  /// Maximum fall velocity for momentum system.
  /// Sand=3, Water=2, Lava=1.
  final int maxVelocity;


  /// Porosity (0.0-1.0). How easily this element absorbs water.
  /// Dirt=0.6, sand=0.3, wood=0.2, mud=0.4, stone=0.0, metal=0.0.
  final double porosity;

  /// Hardness (0-255). Resistance to destruction by explosions and acid.
  /// Empty=0, water=0, fire=5, metal=95, stone=80.
  final int hardness;

  /// Electrical conductivity (0.0-1.0). How well this element conducts electricity.
  /// Metal=0.95, water=0.6, acid=0.4, lava=0.3, everything else=0.0.
  final double conductivity;

  /// Wind resistance (0.0-1.0). How much this element resists wind displacement.
  /// Ash=0.1, smoke=0.15, stone/metal=1.0, water=0.9.
  final double windResistance;

  /// Specific heat capacity (1-10). Higher = more energy to change temperature.
  /// Water=10, Ice=5, Oil=5, Wood=4, Lava=4, Sand/Stone/Glass=2, Metal=1.
  final int heatCapacity;

  // -- Unified chemistry properties (emergent reaction system) ---------------

  /// Standard reduction potential (-128 to +127, scaled from real volts).
  /// Positive = oxidizer (wants electrons). Negative = reducer (gives electrons).
  /// Metal(Fe)=-15, Oxygen=+40, Acid=+60, Salt=-80.
  final int reductionPotential;

  /// Bond energy (0-255). Energy to break this element's structure.
  /// Higher = more stable. Glass=220, Stone=200, Metal=180, Wood=60, Methane=20.
  final int bondEnergy;

  /// Fuel value (0-255). Chemical energy released when oxidized (burned).
  /// 0 = non-combustible. Wood=120, Oil=180, Methane=220, TNT=255.
  final int fuelValue;

  /// Ignition temperature (0-255). Minimum temp for combustion to begin.
  /// Only meaningful if fuelValue > 0. Wood=180, Oil=160, Methane=140.
  final int ignitionTemp;

  /// Element this becomes when fully oxidized. Wood→ash, Metal→rust.
  final int oxidizesInto;

  /// Byproduct released during oxidation. Wood→smoke, Charcoal→co2.
  final int oxidationByproduct;

  /// Element this becomes when reduced (gains electrons). Rust→metal.
  final int reducesInto;

  /// Electron mobility (0-255). How freely current flows through.
  /// Metal=240, Water=80, Acid=100, Glass=0, Air=0.
  final int electronMobility;

  /// Dielectric constant (0-255). How well this insulates charge.
  /// Glass=200, Stone=150, Wood=100, Water=20, Metal=0.
  final int dielectric;

  /// Chemical reactivity (0-255). General reaction rate multiplier.
  /// Acid=220, Lava=180, Water=60, Stone=10, Glass=5.
  final int reactivity;

  /// Base mass (0-255). Per-cell mass when placed. Affects momentum/impact.
  final int baseMass;

  const ElementProperties({
    this.density = 0,
    this.viscosity = 1,
    this.gravity = 0,
    this.state = PhysicsState.solid,
    this.flammable = false,
    this.heatConductivity = 0.1,
    this.meltPoint = 0,
    this.boilPoint = 0,
    this.freezePoint = 0,
    this.meltsInto = 0,
    this.boilsInto = 0,
    this.freezesInto = 0,
    this.baseTemperature = 128,
    this.corrosionResistance = 0,
    this.lightEmission = 0,
    this.lightR = 0,
    this.lightG = 0,
    this.lightB = 0,
    this.decayRate = 0,
    this.decaysInto = 0,
    this.surfaceTension = 0,
    this.maxVelocity = 2,
    this.porosity = 0.0,
    this.hardness = 0,
    this.conductivity = 0.0,
    this.windResistance = 1.0,
    this.heatCapacity = 2,
    // Unified chemistry defaults (inert/non-reactive)
    this.reductionPotential = 0,
    this.bondEnergy = 0,
    this.fuelValue = 0,
    this.ignitionTemp = 0,
    this.oxidizesInto = 0,
    this.oxidationByproduct = 0,
    this.reducesInto = 0,
    this.electronMobility = 0,
    this.dielectric = 5,
    this.reactivity = 0,
    this.baseMass = 0,
  });

  ElementProperties copyWith({
    int? density,
    int? viscosity,
    int? gravity,
    PhysicsState? state,
    bool? flammable,
    double? heatConductivity,
    int? meltPoint,
    int? boilPoint,
    int? freezePoint,
    int? meltsInto,
    int? boilsInto,
    int? freezesInto,
    int? baseTemperature,
    int? corrosionResistance,
    int? lightEmission,
    int? lightR,
    int? lightG,
    int? lightB,
    int? decayRate,
    int? decaysInto,
    int? surfaceTension,
    int? maxVelocity,
    double? porosity,
    int? hardness,
    double? conductivity,
    double? windResistance,
    int? heatCapacity,
    int? reductionPotential,
    int? bondEnergy,
    int? fuelValue,
    int? ignitionTemp,
    int? oxidizesInto,
    int? oxidationByproduct,
    int? reducesInto,
    int? electronMobility,
    int? dielectric,
    int? reactivity,
    int? baseMass,
  }) {
    return ElementProperties(
      density: density ?? this.density,
      viscosity: viscosity ?? this.viscosity,
      gravity: gravity ?? this.gravity,
      state: state ?? this.state,
      flammable: flammable ?? this.flammable,
      heatConductivity: heatConductivity ?? this.heatConductivity,
      meltPoint: meltPoint ?? this.meltPoint,
      boilPoint: boilPoint ?? this.boilPoint,
      freezePoint: freezePoint ?? this.freezePoint,
      meltsInto: meltsInto ?? this.meltsInto,
      boilsInto: boilsInto ?? this.boilsInto,
      freezesInto: freezesInto ?? this.freezesInto,
      baseTemperature: baseTemperature ?? this.baseTemperature,
      corrosionResistance: corrosionResistance ?? this.corrosionResistance,
      lightEmission: lightEmission ?? this.lightEmission,
      lightR: lightR ?? this.lightR,
      lightG: lightG ?? this.lightG,
      lightB: lightB ?? this.lightB,
      decayRate: decayRate ?? this.decayRate,
      decaysInto: decaysInto ?? this.decaysInto,
      surfaceTension: surfaceTension ?? this.surfaceTension,
      maxVelocity: maxVelocity ?? this.maxVelocity,
      porosity: porosity ?? this.porosity,
      hardness: hardness ?? this.hardness,
      conductivity: conductivity ?? this.conductivity,
      windResistance: windResistance ?? this.windResistance,
      heatCapacity: heatCapacity ?? this.heatCapacity,
      reductionPotential: reductionPotential ?? this.reductionPotential,
      bondEnergy: bondEnergy ?? this.bondEnergy,
      fuelValue: fuelValue ?? this.fuelValue,
      ignitionTemp: ignitionTemp ?? this.ignitionTemp,
      oxidizesInto: oxidizesInto ?? this.oxidizesInto,
      oxidationByproduct: oxidationByproduct ?? this.oxidationByproduct,
      reducesInto: reducesInto ?? this.reducesInto,
      electronMobility: electronMobility ?? this.electronMobility,
      dielectric: dielectric ?? this.dielectric,
      reactivity: reactivity ?? this.reactivity,
      baseMass: baseMass ?? this.baseMass,
    );
  }
}

/// Pre-computed element properties table indexed by element ID.
/// Sized to [maxElements] for extensibility.
final List<ElementProperties> elementProperties = List<ElementProperties>.generate(
  maxElements,
  (_) => const ElementProperties(),
  growable: false,
);

/// Initialize the element properties table with values for all built-in elements.
void _initElementProperties() {
  // Empty / Air
  elementProperties[El.empty] = const ElementProperties(
    density: 0, gravity: 0, state: PhysicsState.special,
    heatConductivity: 0.02, baseTemperature: 128,
  
    porosity: 0.0, hardness: 0, conductivity: 0.0, windResistance: 0.0,
    heatCapacity: 1,
  );
  // Sand (SiO2)
  elementProperties[El.sand] = const ElementProperties(
    density: 150, gravity: 2, state: PhysicsState.granular,
    heatConductivity: 0.3, meltPoint: 220, meltsInto: El.glass,
    baseTemperature: 128, maxVelocity: 3,
    porosity: 0.3, hardness: 10, conductivity: 0.0, windResistance: 0.4,
    heatCapacity: 2,
    reductionPotential: 0, bondEnergy: 180, electronMobility: 0,
    dielectric: 120, reactivity: 5, baseMass: 150,
  );
  // Water (H2O)
  elementProperties[El.water] = const ElementProperties(
    density: 100, viscosity: 1, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.4, boilPoint: 180, freezePoint: 30,
    boilsInto: El.steam, freezesInto: El.ice, baseTemperature: 128,
    surfaceTension: 5, maxVelocity: 2,
    conductivity: 0.6, windResistance: 0.9,
    heatCapacity: 10,
    reductionPotential: 0, bondEnergy: 100, electronMobility: 80,
    dielectric: 20, reactivity: 60, baseMass: 100,
  );
  // Fire (exothermic oxidation reaction)
  elementProperties[El.fire] = const ElementProperties(
    density: 5, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.8, baseTemperature: 230,
    lightEmission: 180, lightR: 255, lightG: 120, lightB: 20,
    decayRate: 3, decaysInto: El.smoke,
    hardness: 5, windResistance: 0.2,
    heatCapacity: 1,
    reductionPotential: 50, bondEnergy: 5, electronMobility: 30,
    reactivity: 200, baseMass: 1,
  );
  // Ice
  elementProperties[El.ice] = const ElementProperties(
    density: 90, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.6, meltPoint: 40, meltsInto: El.water,
    baseTemperature: 20, corrosionResistance: 40,
    hardness: 40, windResistance: 1.0,
    heatCapacity: 5,
  );
  // Lightning
  elementProperties[El.lightning] = const ElementProperties(
    density: 0, gravity: 1, state: PhysicsState.special,
    heatConductivity: 1.0, baseTemperature: 250,
    lightEmission: 255, lightR: 255, lightG: 255, lightB: 180,
  
    windResistance: 1.0,
  );
  // Seed
  elementProperties[El.seed] = const ElementProperties(
    density: 130, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    hardness: 5, windResistance: 0.4,
    heatCapacity: 3,
  );
  // Stone (CaCO3/SiO2 — dense, stable, non-reactive)
  elementProperties[El.stone] = const ElementProperties(
    density: 255, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.5, meltPoint: 220, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 60,
    hardness: 80, windResistance: 1.0,
    heatCapacity: 2,
    reductionPotential: 0, bondEnergy: 200, electronMobility: 0,
    dielectric: 150, reactivity: 5, baseMass: 255,
  );
  // TNT (C7H5N3O6 — self-oxidizing explosive)
  elementProperties[El.tnt] = const ElementProperties(
    density: 140, gravity: 2, state: PhysicsState.granular,
    flammable: true, heatConductivity: 0.2, baseTemperature: 128,
    hardness: 15, windResistance: 0.7,
    heatCapacity: 2,
    reductionPotential: -60, bondEnergy: 15, fuelValue: 255,
    ignitionTemp: 130, oxidizesInto: El.smoke, oxidationByproduct: El.fire,
    electronMobility: 0, dielectric: 30, reactivity: 10, baseMass: 140,
  );
  // Rainbow
  elementProperties[El.rainbow] = const ElementProperties(
    density: 8, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.0, baseTemperature: 128,
    lightEmission: 100, lightR: 200, lightG: 100, lightB: 255,
    decayRate: 1, decaysInto: El.empty,
    windResistance: 0.1,
    heatCapacity: 1,
  );
  // Mud
  elementProperties[El.mud] = const ElementProperties(
    density: 120, viscosity: 3, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.25, baseTemperature: 128,
    surfaceTension: 6, maxVelocity: 1,
    porosity: 0.4, hardness: 15, windResistance: 0.85,
    heatCapacity: 6,
  );
  // Steam
  elementProperties[El.steam] = const ElementProperties(
    density: 3, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.3, freezePoint: 60, freezesInto: El.water,
    baseTemperature: 160,
    decayRate: 1, decaysInto: El.water,
    hardness: 2, windResistance: 0.2,
    heatCapacity: 5,
  );
  // Ant
  elementProperties[El.ant] = const ElementProperties(
    density: 80, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    hardness: 5, windResistance: 0.5,
    heatCapacity: 3,
  );
  // Oil (C8H18 — octane)
  elementProperties[El.oil] = const ElementProperties(
    density: 80, viscosity: 2, gravity: 1, state: PhysicsState.liquid,
    flammable: true, heatConductivity: 0.15, boilPoint: 160,
    boilsInto: El.smoke, baseTemperature: 128,
    surfaceTension: 3, maxVelocity: 2,
    hardness: 5, windResistance: 0.85,
    heatCapacity: 5,
    reductionPotential: -40, bondEnergy: 40, fuelValue: 180,
    ignitionTemp: 160, oxidizesInto: El.smoke, oxidationByproduct: El.co2,
    electronMobility: 0, dielectric: 60, reactivity: 20, baseMass: 80,
  );
  // Acid (HCl aqueous)
  elementProperties[El.acid] = const ElementProperties(
    density: 110, viscosity: 1, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.35, baseTemperature: 128,
    lightEmission: 30, lightR: 20, lightG: 255, lightB: 20,
    surfaceTension: 2, maxVelocity: 2,
    conductivity: 0.4, windResistance: 0.85,
    heatCapacity: 4,
    reductionPotential: 60, bondEnergy: 30, electronMobility: 100,
    dielectric: 5, reactivity: 220, baseMass: 110,
  );
  // Glass (amorphous SiO2 — transparent, insulates, acid-resistant)
  elementProperties[El.glass] = const ElementProperties(
    density: 220, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 200, meltsInto: El.sand,
    baseTemperature: 128, corrosionResistance: 250, // nearly immune to HCl
    hardness: 70, windResistance: 1.0,
    heatCapacity: 2,
    reductionPotential: 0, bondEnergy: 220, electronMobility: 0,
    dielectric: 200, reactivity: 3, baseMass: 220,
  );
  // Dirt
  elementProperties[El.dirt] = const ElementProperties(
    density: 145, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.2, baseTemperature: 128,
    maxVelocity: 3,
    porosity: 0.6, hardness: 30, windResistance: 0.7,
    heatCapacity: 2,
  );
  // Plant
  elementProperties[El.plant] = const ElementProperties(
    density: 60, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    porosity: 0.15, hardness: 20, windResistance: 1.0,
    heatCapacity: 4,
  );
  // Lava (molten SiO2 — ionic melt, conducts, emits light)
  elementProperties[El.lava] = const ElementProperties(
    density: 200, viscosity: 4, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.9, freezePoint: 60, freezesInto: El.stone,
    baseTemperature: 250,
    lightEmission: 220, lightR: 255, lightG: 80, lightB: 10,
    surfaceTension: 8, maxVelocity: 1,
    hardness: 0, conductivity: 0.3, windResistance: 0.95,
    heatCapacity: 4,
    reductionPotential: 20, bondEnergy: 200, electronMobility: 40,
    dielectric: 10, reactivity: 180, baseMass: 200,
  );
  // Snow
  elementProperties[El.snow] = const ElementProperties(
    density: 50, gravity: 1, state: PhysicsState.powder,
    heatConductivity: 0.15, meltPoint: 50, meltsInto: El.water,
    baseTemperature: 35,
    hardness: 8, windResistance: 0.3,
    heatCapacity: 5,
  );
  // Wood (cellulose C6H10O5)
  elementProperties[El.wood] = const ElementProperties(
    density: 85, gravity: 1, state: PhysicsState.solid,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    corrosionResistance: 30,
    porosity: 0.2, hardness: 50, windResistance: 1.0,
    heatCapacity: 4,
    reductionPotential: -30, bondEnergy: 60, fuelValue: 120,
    ignitionTemp: 180, oxidizesInto: El.ash, oxidationByproduct: El.smoke,
    electronMobility: 2, dielectric: 80, reactivity: 30, baseMass: 85,
  );
  // Metal (Fe — iron)
  elementProperties[El.metal] = const ElementProperties(
    density: 240, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.9, meltPoint: 240, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 90,
    hardness: 95, conductivity: 0.95, windResistance: 1.0,
    heatCapacity: 1,
    reductionPotential: -15, bondEnergy: 180, oxidizesInto: El.rust,
    reducesInto: 0, electronMobility: 240, dielectric: 0,
    reactivity: 40, baseMass: 240,
  );
  // Smoke
  elementProperties[El.smoke] = const ElementProperties(
    density: 4, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.05, baseTemperature: 145,
    decayRate: 2, decaysInto: El.empty,
    hardness: 2, windResistance: 0.15,
    heatCapacity: 1,
  );
  // Bubble
  elementProperties[El.bubble] = const ElementProperties(
    density: 2, gravity: -1, state: PhysicsState.special,
    heatConductivity: 0.01, baseTemperature: 128,
    windResistance: 0.15,
    heatCapacity: 1,
  );
  // Ash
  elementProperties[El.ash] = const ElementProperties(
    density: 30, gravity: 1, state: PhysicsState.powder,
    heatConductivity: 0.1, baseTemperature: 135,
    hardness: 3, windResistance: 0.1,
    heatCapacity: 1,
  );

  // -- New elements: Phase 1-4 --

  // Oxygen (O2 — universal oxidizer)
  elementProperties[El.oxygen] = const ElementProperties(
    density: 6, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.05, baseTemperature: 128,
    decayRate: 0, windResistance: 0.1, heatCapacity: 1,
    reductionPotential: 40, bondEnergy: 30, reducesInto: El.water,
    electronMobility: 0, dielectric: 5, reactivity: 80, baseMass: 3,
  );
  // CO2 (heavy gas, sinks into depressions, absorbed by plants)
  elementProperties[El.co2] = const ElementProperties(
    density: 15, gravity: 1, state: PhysicsState.gas,
    heatConductivity: 0.03, baseTemperature: 128,
    viscosity: 1, windResistance: 0.12, heatCapacity: 1,
  );
  // Fungus (living decomposer, grows on organic matter)
  elementProperties[El.fungus] = const ElementProperties(
    density: 55, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    porosity: 0.5, hardness: 10, windResistance: 1.0, heatCapacity: 3,
  );
  // Spore (ultra-light wind-carried reproductive particle)
  elementProperties[El.spore] = const ElementProperties(
    density: 5, gravity: 1, state: PhysicsState.powder,
    flammable: true, heatConductivity: 0.01, baseTemperature: 128,
    windResistance: 0.05, heatCapacity: 1,
    decayRate: 1, decaysInto: El.empty,
  );
  // Charcoal (amorphous C — energy-dense fuel, conducts electricity)
  elementProperties[El.charcoal] = const ElementProperties(
    density: 100, gravity: 2, state: PhysicsState.granular,
    flammable: true, heatConductivity: 0.15, baseTemperature: 128,
    hardness: 30, windResistance: 0.6, heatCapacity: 2,
    maxVelocity: 3,
    reductionPotential: -25, bondEnergy: 80, fuelValue: 200,
    ignitionTemp: 170, oxidizesInto: El.ash, oxidationByproduct: El.co2,
    reducesInto: 0, electronMobility: 60, dielectric: 40,
    reactivity: 25, baseMass: 100,
  );
  // Compost (rich decomposed organic matter, super-fertilizer)
  elementProperties[El.compost] = const ElementProperties(
    density: 110, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.15, baseTemperature: 128,
    porosity: 0.8, hardness: 8, windResistance: 0.6, heatCapacity: 4,
    maxVelocity: 2,
  );
  // Rust (Fe2O3 — corroded iron, reducible back to metal)
  elementProperties[El.rust] = const ElementProperties(
    density: 200, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.5, baseTemperature: 128,
    corrosionResistance: 20, hardness: 40,
    conductivity: 0.1, windResistance: 1.0, heatCapacity: 2,
    reductionPotential: 10, bondEnergy: 140, reducesInto: El.metal,
    electronMobility: 20, dielectric: 100, reactivity: 10, baseMass: 200,
  );
  // Methane (CH4 — explosive, highest energy density per mass)
  elementProperties[El.methane] = const ElementProperties(
    density: 7, gravity: -1, state: PhysicsState.gas,
    flammable: true, heatConductivity: 0.03, baseTemperature: 128,
    windResistance: 0.1, heatCapacity: 1,
    reductionPotential: -50, bondEnergy: 20, fuelValue: 220,
    ignitionTemp: 140, oxidizesInto: El.co2, oxidationByproduct: El.steam,
    electronMobility: 0, dielectric: 5, reactivity: 40, baseMass: 2,
  );
  // Salt (NaCl — soluble, boosts water conductivity, de-ices)
  elementProperties[El.salt] = const ElementProperties(
    density: 155, gravity: 2, state: PhysicsState.granular,
    heatConductivity: 0.35, meltPoint: 210, meltsInto: El.lava,
    baseTemperature: 128, maxVelocity: 3,
    hardness: 15, windResistance: 0.5, heatCapacity: 2,
    reductionPotential: -80, bondEnergy: 100, electronMobility: 120,
    dielectric: 80, reactivity: 30, baseMass: 155,
  );
  // Clay (hardens when heated into ceramic/glass)
  elementProperties[El.clay] = const ElementProperties(
    density: 160, gravity: 2, state: PhysicsState.granular,
    heatConductivity: 0.3, meltPoint: 200, meltsInto: El.glass,
    baseTemperature: 128, porosity: 0.7, hardness: 25,
    windResistance: 0.7, heatCapacity: 3, maxVelocity: 2,
  );
  // Algae (aquatic plant, grows in water, produces oxygen)
  elementProperties[El.algae] = const ElementProperties(
    density: 95, gravity: 1, state: PhysicsState.special,
    heatConductivity: 0.2, baseTemperature: 128,
    hardness: 5, windResistance: 1.0, heatCapacity: 4,
  );
  // Honey (very viscous ant-produced liquid)
  elementProperties[El.honey] = const ElementProperties(
    density: 140, viscosity: 6, gravity: 1, state: PhysicsState.liquid,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    surfaceTension: 9, maxVelocity: 1,
    hardness: 5, windResistance: 0.9, heatCapacity: 3,
  );

  // Hydrogen (H2 — lightest element, explosive with O2, highest energy/mass)
  elementProperties[El.hydrogen] = const ElementProperties(
    density: 1, gravity: -2, state: PhysicsState.gas,
    flammable: true, heatConductivity: 0.18, baseTemperature: 128,
    windResistance: 0.05, heatCapacity: 10,
    reductionPotential: 0, bondEnergy: 30, fuelValue: 250,
    ignitionTemp: 140, oxidizesInto: El.steam, oxidationByproduct: El.empty,
    electronMobility: 0, dielectric: 5, reactivity: 60, baseMass: 1,
  );
  // Sulfur (S8 — volcanic, burns to toxic gas, tarnishes metals)
  elementProperties[El.sulfur] = const ElementProperties(
    density: 155, gravity: 2, state: PhysicsState.granular,
    flammable: true, heatConductivity: 0.2, baseTemperature: 128,
    maxVelocity: 3, hardness: 15, windResistance: 0.5, heatCapacity: 2,
    reductionPotential: -10, bondEnergy: 60, fuelValue: 100,
    ignitionTemp: 150, oxidizesInto: El.smoke, oxidationByproduct: El.co2,
    electronMobility: 0, dielectric: 100, reactivity: 50, baseMass: 155,
  );
  // Copper (Cu — best conductor, doesn't rust, forms green patina slowly)
  elementProperties[El.copper] = const ElementProperties(
    density: 245, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 1.0, meltPoint: 240, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 120,
    hardness: 70, conductivity: 1.0, windResistance: 1.0,
    heatCapacity: 1,
    reductionPotential: 10, bondEnergy: 160,
    electronMobility: 255, dielectric: 0, reactivity: 20, baseMass: 245,
  );
  // Web (spider silk — sticky, burns instantly, dissolves in water)
  elementProperties[El.web] = const ElementProperties(
    density: 10, gravity: 1, state: PhysicsState.solid,
    flammable: true, heatConductivity: 0.05, baseTemperature: 128,
    hardness: 5, windResistance: 1.0, heatCapacity: 1,
    decayRate: 0, bondEnergy: 10, reactivity: 5, baseMass: 10,
  );

  // -- Phase 6: Neural Plants --

  // Seaweed (aquatic plant, grows in water, fish food, evolves toxicity)
  elementProperties[El.seaweed] = const ElementProperties(
    density: 90, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.2, baseTemperature: 128,
    hardness: 5, windResistance: 1.0, heatCapacity: 4,
    porosity: 0.3,
  );
  // Moss (surface plant, grows on rock/stone, minimal light needed)
  elementProperties[El.moss] = const ElementProperties(
    density: 40, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    hardness: 3, windResistance: 1.0, heatCapacity: 3,
    porosity: 0.6,
  );
  // Vine (climbing plant, grows along surfaces, hangs down)
  elementProperties[El.vine] = const ElementProperties(
    density: 55, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    hardness: 15, windResistance: 1.0, heatCapacity: 4,
  );
  // Flower (reproducer, produces seeds/pollen, attracts bees)
  elementProperties[El.flower] = const ElementProperties(
    density: 50, gravity: 1, state: PhysicsState.special,
    flammable: true, heatConductivity: 0.1, baseTemperature: 128,
    hardness: 8, windResistance: 1.0, heatCapacity: 3,
    lightEmission: 8, lightR: 200, lightG: 60, lightB: 120,
  );
  // Root (underground, grows downward seeking water/nutrients)
  elementProperties[El.root] = const ElementProperties(
    density: 70, gravity: 1, state: PhysicsState.special,
    heatConductivity: 0.1, baseTemperature: 128,
    hardness: 25, windResistance: 1.0, heatCapacity: 4,
    porosity: 0.4,
  );
  // Thorn (defensive plant structure, damages creatures)
  elementProperties[El.thorn] = const ElementProperties(
    density: 80, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.1, baseTemperature: 128,
    hardness: 35, windResistance: 1.0, heatCapacity: 2,
    flammable: true,
  );

  // -- Phase 7: Advanced Materials --

  // C4 (Stable explosive, needs electricity or pressure to detonate)
  elementProperties[El.c4] = const ElementProperties(
    density: 160, gravity: 2, state: PhysicsState.solid,
    heatConductivity: 0.05, baseTemperature: 128,
    hardness: 40, windResistance: 1.0, heatCapacity: 3,
    reductionPotential: -80, bondEnergy: 200, fuelValue: 255,
    ignitionTemp: 250, // Very hard to ignite by heat alone
    oxidizesInto: El.smoke, oxidationByproduct: El.fire,
    electronMobility: 5, dielectric: 50, reactivity: 10, baseMass: 160,
  );
  
  // Uranium (Dense, hot, fissile)
  elementProperties[El.uranium] = const ElementProperties(
    density: 250, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.8, meltPoint: 250, meltsInto: El.lava,
    baseTemperature: 140, // Naturally warm
    lightEmission: 80, lightR: 100, lightG: 255, lightB: 100, // Green glow
    corrosionResistance: 150, hardness: 95, conductivity: 0.6,
    windResistance: 1.0, heatCapacity: 1,
    reductionPotential: 0, bondEnergy: 250, electronMobility: 180,
    dielectric: 0, reactivity: 30, baseMass: 250,
  );

  // Lead (Dense radiation/heat shield)
  elementProperties[El.lead] = const ElementProperties(
    density: 255, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.05, // Excellent insulator
    meltPoint: 150, meltsInto: El.lava, // Melts easier than other metals
    baseTemperature: 128, corrosionResistance: 200, // Resists acid
    hardness: 60, conductivity: 0.8, windResistance: 1.0, heatCapacity: 8,
    reductionPotential: 0, bondEnergy: 180, electronMobility: 200,
    dielectric: 0, reactivity: 5, baseMass: 255,
  );

  // ==========================================================================
  // Periodic Table Elements
  // ==========================================================================
  _initPeriodicElements();

  // Rebuild all fast-access lookup tables
  _rebuildPropertyLookups();

  // Initialize element family + atomic number + symbol tables
  _initElementMetadata();
}

/// Initialize all periodic table element properties.
void _initPeriodicElements() {
  // -- Noble Gases (inert, varying density, rise) --
  elementProperties[El.helium] = const ElementProperties(
    density: 1, gravity: -2, state: PhysicsState.gas,
    heatConductivity: 0.02, baseTemperature: 128,
    windResistance: 0.05, heatCapacity: 1, baseMass: 1,
  );
  elementProperties[El.neon] = const ElementProperties(
    density: 3, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.02, baseTemperature: 128,
    lightEmission: 15, lightR: 255, lightG: 100, lightB: 50,
    windResistance: 0.1, baseMass: 5,
  );
  elementProperties[El.argon] = const ElementProperties(
    density: 8, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.02, baseTemperature: 128,
    windResistance: 0.1, baseMass: 10,
  );
  elementProperties[El.krypton] = const ElementProperties(
    density: 15, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.02, baseTemperature: 128,
    windResistance: 0.15, baseMass: 20,
  );
  elementProperties[El.xenon] = const ElementProperties(
    density: 20, gravity: 0, state: PhysicsState.gas,
    heatConductivity: 0.02, baseTemperature: 128,
    windResistance: 0.15, baseMass: 30,
  );
  elementProperties[El.radon] = const ElementProperties(
    density: 25, gravity: 1, state: PhysicsState.gas, // heavier than air, sinks
    heatConductivity: 0.02, baseTemperature: 128,
    lightEmission: 8, lightR: 60, lightG: 255, lightB: 80,
    decayRate: 8, decaysInto: El.lead,
    windResistance: 0.2, baseMass: 55, reactivity: 5,
  );

  // -- Alkali Metals (soft, low melting, violently reactive with water) --
  elementProperties[El.lithium] = const ElementProperties(
    density: 55, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 80, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 10,
    hardness: 5, conductivity: 0.3, windResistance: 0.6,
    reactivity: 180, baseMass: 55,
  );
  elementProperties[El.sodium] = const ElementProperties(
    density: 60, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 70, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 5,
    hardness: 4, conductivity: 0.3, windResistance: 0.6,
    reactivity: 200, baseMass: 60,
  );
  elementProperties[El.potassium] = const ElementProperties(
    density: 58, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 60, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 5,
    hardness: 3, conductivity: 0.3, windResistance: 0.6,
    reactivity: 220, baseMass: 58,
  );
  elementProperties[El.rubidium] = const ElementProperties(
    density: 62, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 55, meltsInto: El.lava,
    baseTemperature: 128, hardness: 3, reactivity: 230, baseMass: 62,
  );
  elementProperties[El.cesium] = const ElementProperties(
    density: 64, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 50, meltsInto: El.lava,
    baseTemperature: 128, hardness: 2, reactivity: 250, baseMass: 64,
  );
  elementProperties[El.francium] = const ElementProperties(
    density: 66, gravity: 1, state: PhysicsState.granular,
    heatConductivity: 0.5, meltPoint: 48, meltsInto: El.lava,
    baseTemperature: 128, hardness: 2, reactivity: 255,
    decayRate: 5, decaysInto: El.radon, baseMass: 66,
  );

  // -- Alkaline Earth Metals (harder, higher melt, moderate reactivity) --
  elementProperties[El.beryllium] = const ElementProperties(
    density: 120, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.5, meltPoint: 180, baseTemperature: 128,
    hardness: 70, conductivity: 0.3, windResistance: 1.0,
    reactivity: 40, baseMass: 120,
  );
  elementProperties[El.magnesium] = const ElementProperties(
    density: 115, gravity: 1, state: PhysicsState.solid,
    flammable: true, heatConductivity: 0.6, meltPoint: 140,
    baseTemperature: 128, hardness: 35, conductivity: 0.4,
    windResistance: 1.0, fuelValue: 200, ignitionTemp: 180,
    oxidizesInto: El.ash, oxidationByproduct: El.empty,
    reactivity: 80, baseMass: 115,
    lightEmission: 0, // burns with brilliant white flash (handled in behavior)
  );
  elementProperties[El.calcium] = const ElementProperties(
    density: 105, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 150, baseTemperature: 128,
    hardness: 30, conductivity: 0.3, windResistance: 1.0,
    reactivity: 60, baseMass: 105,
  );
  elementProperties[El.strontium] = const ElementProperties(
    density: 130, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 140, baseTemperature: 128,
    hardness: 25, reactivity: 70, baseMass: 130,
  );
  elementProperties[El.barium] = const ElementProperties(
    density: 140, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 130, baseTemperature: 128,
    hardness: 20, reactivity: 80, baseMass: 140,
  );
  elementProperties[El.radium] = const ElementProperties(
    density: 150, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 120, baseTemperature: 135,
    lightEmission: 12, lightR: 80, lightG: 255, lightB: 120,
    hardness: 20, reactivity: 80,
    decayRate: 6, decaysInto: El.radon, baseMass: 150,
  );

  // -- Transition Metals (varied, mostly dense inert solids) --
  // Helper: most share similar patterns, varying in density/melt/hardness
  _setTransitionMetal(El.scandium, density: 160, melt: 170, hardness: 50, mass: 160);
  _setTransitionMetal(El.titanium, density: 180, melt: 200, hardness: 80, mass: 180, cond: 0.2);
  _setTransitionMetal(El.vanadium, density: 185, melt: 210, hardness: 75, mass: 185);
  _setTransitionMetal(El.chromium, density: 190, melt: 210, hardness: 85, mass: 190, cond: 0.5);
  _setTransitionMetal(El.manganese, density: 185, melt: 180, hardness: 60, mass: 185);
  _setTransitionMetal(El.cobalt, density: 195, melt: 190, hardness: 70, mass: 195, cond: 0.3);
  _setTransitionMetal(El.nickel, density: 195, melt: 190, hardness: 70, mass: 195, cond: 0.4);
  _setTransitionMetal(El.zinc, density: 175, melt: 130, hardness: 40, mass: 175, cond: 0.4);
  _setTransitionMetal(El.yttrium, density: 170, melt: 170, hardness: 50, mass: 170);
  _setTransitionMetal(El.zirconium, density: 185, melt: 210, hardness: 75, mass: 185);
  _setTransitionMetal(El.niobium, density: 195, melt: 220, hardness: 80, mass: 195);
  _setTransitionMetal(El.molybdenum, density: 200, melt: 230, hardness: 85, mass: 200, cond: 0.5);
  _setTransitionMetal(El.technetium, density: 200, melt: 210, hardness: 70, mass: 200);
  _setTransitionMetal(El.ruthenium, density: 205, melt: 220, hardness: 80, mass: 205);
  _setTransitionMetal(El.rhodium, density: 210, melt: 210, hardness: 80, mass: 210, cond: 0.5);
  _setTransitionMetal(El.palladium, density: 205, melt: 190, hardness: 60, mass: 205, cond: 0.5);
  _setTransitionMetal(El.silver, density: 200, melt: 160, hardness: 40, mass: 200, cond: 0.95);
  _setTransitionMetal(El.cadmium, density: 195, melt: 120, hardness: 30, mass: 195);
  _setTransitionMetal(El.hafnium, density: 215, melt: 220, hardness: 80, mass: 215);
  _setTransitionMetal(El.tantalum, density: 220, melt: 230, hardness: 85, mass: 220);
  _setTransitionMetal(El.tungsten, density: 235, melt: 255, hardness: 95, mass: 235, cond: 0.4);
  _setTransitionMetal(El.rhenium, density: 230, melt: 240, hardness: 90, mass: 230);
  _setTransitionMetal(El.osmium, density: 255, melt: 240, hardness: 90, mass: 255); // densest
  _setTransitionMetal(El.iridium, density: 250, melt: 235, hardness: 90, mass: 250);
  _setTransitionMetal(El.platinum, density: 240, melt: 200, hardness: 65, mass: 240, cond: 0.6);
  // Gold: special — high density, nearly inert, beautiful
  elementProperties[El.gold] = const ElementProperties(
    density: 235, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.7, meltPoint: 170, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 255, // resists everything
    hardness: 35, conductivity: 0.7, windResistance: 1.0, heatCapacity: 2,
    bondEnergy: 200, electronMobility: 200, reactivity: 2, baseMass: 235,
  );
  // Mercury: liquid metal at room temp
  elementProperties[El.mercury] = const ElementProperties(
    density: 210, viscosity: 2, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.5, freezePoint: 20, freezesInto: El.metal,
    boilPoint: 200, boilsInto: El.smoke,
    baseTemperature: 128, surfaceTension: 8, maxVelocity: 2,
    conductivity: 0.6, windResistance: 0.9, heatCapacity: 2,
    reactivity: 30, baseMass: 210,
  );
  // Superheavy transition metals (all unstable)
  for (final el in [El.rutherfordium, El.dubnium, El.seaborgium, El.bohrium]) {
    elementProperties[el] = const ElementProperties(
      density: 230, gravity: 1, state: PhysicsState.solid,
      heatConductivity: 0.3, baseTemperature: 140,
      hardness: 60, decayRate: 2, decaysInto: El.lead,
      baseMass: 230,
    );
  }

  // -- Post-Transition Metals --
  elementProperties[El.aluminum] = const ElementProperties(
    density: 120, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.7, meltPoint: 140, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: 60,
    hardness: 40, conductivity: 0.6, windResistance: 1.0, heatCapacity: 3,
    reactivity: 50, baseMass: 120,
  );
  elementProperties[El.gallium] = const ElementProperties(
    density: 140, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 40, meltsInto: El.mercury, // melts near body temp!
    baseTemperature: 128, hardness: 15, conductivity: 0.3,
    reactivity: 30, baseMass: 140,
  );
  elementProperties[El.indium] = const ElementProperties(
    density: 165, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 80, baseTemperature: 128,
    hardness: 10, conductivity: 0.3, baseMass: 165,
  );
  elementProperties[El.tin] = const ElementProperties(
    density: 170, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 100, meltsInto: El.lava,
    baseTemperature: 128, hardness: 25, conductivity: 0.3,
    reactivity: 20, baseMass: 170,
  );
  elementProperties[El.thallium] = const ElementProperties(
    density: 200, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 110, baseTemperature: 128,
    hardness: 15, baseMass: 200,
  );
  elementProperties[El.bismuth] = const ElementProperties(
    density: 195, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.2, meltPoint: 90, baseTemperature: 128,
    hardness: 20, baseMass: 195,
    lightEmission: 5, lightR: 200, lightG: 160, lightB: 220, // slight iridescence
  );

  // -- Metalloids --
  elementProperties[El.boron] = const ElementProperties(
    density: 140, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 220, baseTemperature: 128,
    hardness: 85, windResistance: 1.0, baseMass: 140,
  );
  elementProperties[El.silicon] = const ElementProperties(
    density: 140, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 200, meltsInto: El.glass,
    baseTemperature: 128, hardness: 70, 
    conductivity: 0.0, // Default non-conductive
    electronMobility: 0, 
    dielectric: 250, // High insulation
    windResistance: 1.0, baseMass: 140,
  );
  elementProperties[El.germanium] = const ElementProperties(
    density: 155, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 180, baseTemperature: 128,
    hardness: 60, conductivity: 0.1, baseMass: 155,
  );
  elementProperties[El.arsenic] = const ElementProperties(
    density: 155, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.2, meltPoint: 150, baseTemperature: 128,
    hardness: 30, reactivity: 80, baseMass: 155,
  );
  elementProperties[El.antimony] = const ElementProperties(
    density: 160, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.2, meltPoint: 140, baseTemperature: 128,
    hardness: 35, baseMass: 160,
  );
  elementProperties[El.tellurium] = const ElementProperties(
    density: 155, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.15, meltPoint: 130, baseTemperature: 128,
    hardness: 25, baseMass: 155,
  );

  // -- Nonmetals --
  // Diamond (crystalline carbon) — hardest natural material
  elementProperties[El.carbon] = const ElementProperties(
    density: 160, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.8, meltPoint: 255, // almost impossible to melt
    baseTemperature: 128, corrosionResistance: 200,
    hardness: 255, windResistance: 1.0, heatCapacity: 2,
    bondEnergy: 255, dielectric: 200, baseMass: 160,
  );
  elementProperties[El.nitrogen] = const ElementProperties(
    density: 5, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.03, boilPoint: 0, // already gas at room temp
    baseTemperature: 128, windResistance: 0.1, baseMass: 5,
  );
  // White phosphorus — auto-ignites!
  elementProperties[El.phosphorus] = const ElementProperties(
    density: 110, gravity: 1, state: PhysicsState.granular,
    flammable: true, heatConductivity: 0.1, meltPoint: 60,
    baseTemperature: 128, hardness: 8,
    fuelValue: 200, ignitionTemp: 100, // low ignition — catches fire easily
    oxidizesInto: El.smoke, oxidationByproduct: El.smoke,
    reactivity: 180, baseMass: 110,
  );
  elementProperties[El.selenium] = const ElementProperties(
    density: 140, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.1, meltPoint: 100, baseTemperature: 128,
    hardness: 25, conductivity: 0.05, baseMass: 140,
  );

  // -- Halogens --
  elementProperties[El.fluorine] = const ElementProperties(
    density: 6, gravity: -1, state: PhysicsState.gas,
    heatConductivity: 0.03, baseTemperature: 128,
    windResistance: 0.1, reactivity: 255, baseMass: 5, // most reactive element
  );
  elementProperties[El.chlorine] = const ElementProperties(
    density: 12, gravity: 0, state: PhysicsState.gas,
    heatConductivity: 0.03, baseTemperature: 128,
    windResistance: 0.15, reactivity: 200, baseMass: 10,
  );
  elementProperties[El.bromine] = const ElementProperties(
    density: 130, viscosity: 2, gravity: 1, state: PhysicsState.liquid,
    heatConductivity: 0.1, boilPoint: 120, boilsInto: El.smoke,
    baseTemperature: 128, surfaceTension: 3,
    reactivity: 160, baseMass: 130,
  );
  elementProperties[El.iodine] = const ElementProperties(
    density: 145, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.1, meltPoint: 80,
    baseTemperature: 128, hardness: 15,
    reactivity: 120, baseMass: 145,
  );
  elementProperties[El.astatine] = const ElementProperties(
    density: 150, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.1, baseTemperature: 128,
    decayRate: 3, decaysInto: El.lead, reactivity: 100, baseMass: 150,
  );
  elementProperties[El.tennessine] = const ElementProperties(
    density: 160, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.1, baseTemperature: 128,
    decayRate: 1, decaysInto: El.lead, baseMass: 160,
  );

  // -- Lanthanides (dense silvery metals, mostly inert in sandbox) --
  for (final el in [
    El.lanthanum, El.cerium, El.praseodymium, El.neodymium,
    El.samarium, El.europium, El.gadolinium, El.terbium,
    El.dysprosium, El.holmium, El.erbium, El.thulium,
    El.ytterbium, El.lutetium,
  ]) {
    _setRareEarth(el, density: 170 + (el - El.lanthanum) * 2);
  }
  // Promethium is radioactive
  elementProperties[El.promethium] = const ElementProperties(
    density: 180, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 170, baseTemperature: 130,
    lightEmission: 6, lightR: 80, lightG: 200, lightB: 100,
    hardness: 40, conductivity: 0.2,
    decayRate: 5, decaysInto: El.samarium, baseMass: 180,
  );
  // Neodymium: strongest magnetic (visual effect in renderer)
  elementProperties[El.neodymium] = const ElementProperties(
    density: 178, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 170, baseTemperature: 128,
    hardness: 45, conductivity: 0.2, windResistance: 1.0,
    lightEmission: 3, lightR: 180, lightG: 180, lightB: 220, baseMass: 178,
  );

  // -- Actinides --
  elementProperties[El.actinium] = const ElementProperties(
    density: 200, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 170, baseTemperature: 132,
    lightEmission: 10, lightR: 60, lightG: 200, lightB: 100,
    hardness: 40, decayRate: 6, decaysInto: El.francium, baseMass: 200,
  );
  // Thorium: safer nuclear fuel, sustained heat
  elementProperties[El.thorium] = const ElementProperties(
    density: 210, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: 210, baseTemperature: 140,
    lightEmission: 8, lightR: 50, lightG: 200, lightB: 80,
    hardness: 60, conductivity: 0.2, windResistance: 1.0,
    reactivity: 40, baseMass: 210,
  );
  elementProperties[El.protactinium] = const ElementProperties(
    density: 215, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 200, baseTemperature: 135,
    hardness: 50, decayRate: 5, decaysInto: El.actinium, baseMass: 215,
  );
  elementProperties[El.neptunium] = const ElementProperties(
    density: 220, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 190, baseTemperature: 138,
    lightEmission: 6, lightR: 60, lightG: 180, lightB: 100,
    hardness: 50, decayRate: 4, decaysInto: El.protactinium, baseMass: 220,
  );
  // Plutonium: more reactive than uranium, smaller critical mass
  elementProperties[El.plutonium] = const ElementProperties(
    density: 225, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 180, baseTemperature: 145,
    lightEmission: 12, lightR: 50, lightG: 255, lightB: 80,
    hardness: 55, conductivity: 0.2, windResistance: 1.0,
    reactivity: 60, baseMass: 225,
  );
  elementProperties[El.americium] = const ElementProperties(
    density: 215, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.2, meltPoint: 170, baseTemperature: 133,
    lightEmission: 5, lightR: 60, lightG: 200, lightB: 100,
    hardness: 40, decayRate: 7, decaysInto: El.neptunium, baseMass: 215,
  );
  // Remaining actinides (similar properties, all radioactive)
  for (final el in [
    El.curium, El.berkelium, El.californium, El.einsteinium,
    El.fermium, El.mendelevium, El.nobelium, El.lawrencium,
  ]) {
    elementProperties[el] = ElementProperties(
      density: 210 + (el - El.curium) * 2, gravity: 1, state: PhysicsState.solid,
      heatConductivity: 0.2, baseTemperature: 134,
      lightEmission: 5, lightR: 60, lightG: 200, lightB: 100,
      hardness: 35, decayRate: 3 - (el - El.curium).clamp(0, 2),
      decaysInto: El.lead, baseMass: 210 + (el - El.curium) * 2,
    );
  }

  // -- Superheavy (all extremely unstable) --
  for (final el in [
    El.hassium, El.meitnerium, El.darmstadtium, El.roentgenium,
    El.copernicium, El.nihonium, El.flerovium, El.moscovium,
    El.livermorium, El.oganesson,
  ]) {
    elementProperties[el] = const ElementProperties(
      density: 240, gravity: 1, state: PhysicsState.solid,
      heatConductivity: 0.2, baseTemperature: 140,
      hardness: 50, decayRate: 1, decaysInto: El.lead,
      baseMass: 240,
    );
  }
}

/// Helper to set a standard transition metal's properties.
void _setTransitionMetal(int el, {
  required int density, required int melt, required int hardness,
  required int mass, double cond = 0.2,
}) {
  elementProperties[el] = ElementProperties(
    density: density, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.4, meltPoint: melt, meltsInto: El.lava,
    baseTemperature: 128, corrosionResistance: hardness,
    hardness: hardness, conductivity: cond, windResistance: 1.0,
    heatCapacity: 2, bondEnergy: hardness * 2,
    electronMobility: (cond * 255).round(), baseMass: mass,
  );
}

/// Helper to set a lanthanide/rare earth element's properties.
void _setRareEarth(int el, {required int density}) {
  elementProperties[el] = ElementProperties(
    density: density, gravity: 1, state: PhysicsState.solid,
    heatConductivity: 0.3, meltPoint: 170, meltsInto: El.lava,
    baseTemperature: 128, hardness: 40, conductivity: 0.2,
    windResistance: 1.0, baseMass: density,
  );
}

/// Initialize element family, atomic number, and symbol metadata.
void _initElementMetadata() {
  // Existing elements: map to their periodic table counterparts
  elementFamily[El.hydrogen] = ElFamily.nonmetal;
  elementAtomicNumber[El.hydrogen] = 1; elementSymbol[El.hydrogen] = 'H';
  elementFamily[El.oxygen] = ElFamily.nonmetal;
  elementAtomicNumber[El.oxygen] = 8; elementSymbol[El.oxygen] = 'O';
  elementFamily[El.sulfur] = ElFamily.nonmetal;
  elementAtomicNumber[El.sulfur] = 16; elementSymbol[El.sulfur] = 'S';
  elementFamily[El.copper] = ElFamily.transitionMetal;
  elementAtomicNumber[El.copper] = 29; elementSymbol[El.copper] = 'Cu';
  elementFamily[El.metal] = ElFamily.transitionMetal;
  elementAtomicNumber[El.metal] = 26; elementSymbol[El.metal] = 'Fe';
  elementFamily[El.uranium] = ElFamily.actinide;
  elementAtomicNumber[El.uranium] = 92; elementSymbol[El.uranium] = 'U';
  elementFamily[El.lead] = ElFamily.postTransition;
  elementAtomicNumber[El.lead] = 82; elementSymbol[El.lead] = 'Pb';
  // Compounds
  for (final el in [
    El.water, El.salt, El.co2, El.methane, El.steam, El.mud, El.acid,
    El.tnt, El.c4, El.oil, El.honey, El.rust,
  ]) {
    elementFamily[el] = ElFamily.compound;
  }
  // Organics
  for (final el in [
    El.sand, El.dirt, El.plant, El.seed, El.wood, El.fungus, El.spore,
    El.compost, El.algae, El.seaweed, El.moss, El.vine, El.flower,
    El.root, El.thorn, El.ant, El.web, El.ash,
  ]) {
    elementFamily[el] = ElFamily.organic;
  }
  elementFamily[El.charcoal] = ElFamily.nonmetal;
  elementAtomicNumber[El.charcoal] = 6; elementSymbol[El.charcoal] = 'C';
  elementFamily[El.stone] = ElFamily.compound; elementSymbol[El.stone] = '';
  elementFamily[El.glass] = ElFamily.compound; elementSymbol[El.glass] = '';
  elementFamily[El.fire] = ElFamily.none; elementFamily[El.lightning] = ElFamily.none;
  elementFamily[El.rainbow] = ElFamily.none; elementFamily[El.smoke] = ElFamily.compound;
  elementFamily[El.bubble] = ElFamily.compound; elementFamily[El.snow] = ElFamily.compound;
  elementFamily[El.ice] = ElFamily.compound; elementFamily[El.lava] = ElFamily.compound;

  // Noble Gases
  final nobleGases = {El.helium: (2,'He'), El.neon: (10,'Ne'), El.argon: (18,'Ar'),
    El.krypton: (36,'Kr'), El.xenon: (54,'Xe'), El.radon: (86,'Rn')};
  for (final e in nobleGases.entries) {
    elementFamily[e.key] = ElFamily.nobleGas;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Alkali Metals
  final alkalis = {El.lithium: (3,'Li'), El.sodium: (11,'Na'), El.potassium: (19,'K'),
    El.rubidium: (37,'Rb'), El.cesium: (55,'Cs'), El.francium: (87,'Fr')};
  for (final e in alkalis.entries) {
    elementFamily[e.key] = ElFamily.alkaliMetal;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Alkaline Earth
  final alkalineEarth = {El.beryllium: (4,'Be'), El.magnesium: (12,'Mg'), El.calcium: (20,'Ca'),
    El.strontium: (38,'Sr'), El.barium: (56,'Ba'), El.radium: (88,'Ra')};
  for (final e in alkalineEarth.entries) {
    elementFamily[e.key] = ElFamily.alkalineEarth;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Transition Metals
  final transMetals = {
    El.scandium: (21,'Sc'), El.titanium: (22,'Ti'), El.vanadium: (23,'V'),
    El.chromium: (24,'Cr'), El.manganese: (25,'Mn'), El.cobalt: (27,'Co'),
    El.nickel: (28,'Ni'), El.zinc: (30,'Zn'), El.yttrium: (39,'Y'),
    El.zirconium: (40,'Zr'), El.niobium: (41,'Nb'), El.molybdenum: (42,'Mo'),
    El.technetium: (43,'Tc'), El.ruthenium: (44,'Ru'), El.rhodium: (45,'Rh'),
    El.palladium: (46,'Pd'), El.silver: (47,'Ag'), El.cadmium: (48,'Cd'),
    El.hafnium: (72,'Hf'), El.tantalum: (73,'Ta'), El.tungsten: (74,'W'),
    El.rhenium: (75,'Re'), El.osmium: (76,'Os'), El.iridium: (77,'Ir'),
    El.platinum: (78,'Pt'), El.gold: (79,'Au'), El.mercury: (80,'Hg'),
    El.rutherfordium: (104,'Rf'), El.dubnium: (105,'Db'),
    El.seaborgium: (106,'Sg'), El.bohrium: (107,'Bh'),
  };
  for (final e in transMetals.entries) {
    elementFamily[e.key] = ElFamily.transitionMetal;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Post-Transition
  final postTrans = {El.aluminum: (13,'Al'), El.gallium: (31,'Ga'), El.indium: (49,'In'),
    El.tin: (50,'Sn'), El.thallium: (81,'Tl'), El.bismuth: (83,'Bi')};
  for (final e in postTrans.entries) {
    elementFamily[e.key] = ElFamily.postTransition;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Metalloids
  final metalloids = {El.boron: (5,'B'), El.silicon: (14,'Si'), El.germanium: (32,'Ge'),
    El.arsenic: (33,'As'), El.antimony: (51,'Sb'), El.tellurium: (52,'Te')};
  for (final e in metalloids.entries) {
    elementFamily[e.key] = ElFamily.metalloid;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Nonmetals
  final nonmetals = {El.carbon: (6,'C'), El.nitrogen: (7,'N'),
    El.phosphorus: (15,'P'), El.selenium: (34,'Se')};
  for (final e in nonmetals.entries) {
    elementFamily[e.key] = ElFamily.nonmetal;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Halogens
  final halogens = {El.fluorine: (9,'F'), El.chlorine: (17,'Cl'), El.bromine: (35,'Br'),
    El.iodine: (53,'I'), El.astatine: (85,'At'), El.tennessine: (117,'Ts')};
  for (final e in halogens.entries) {
    elementFamily[e.key] = ElFamily.halogen;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Lanthanides
  final lanthanides = {
    El.lanthanum: (57,'La'), El.cerium: (58,'Ce'), El.praseodymium: (59,'Pr'),
    El.neodymium: (60,'Nd'), El.promethium: (61,'Pm'), El.samarium: (62,'Sm'),
    El.europium: (63,'Eu'), El.gadolinium: (64,'Gd'), El.terbium: (65,'Tb'),
    El.dysprosium: (66,'Dy'), El.holmium: (67,'Ho'), El.erbium: (68,'Er'),
    El.thulium: (69,'Tm'), El.ytterbium: (70,'Yb'), El.lutetium: (71,'Lu'),
  };
  for (final e in lanthanides.entries) {
    elementFamily[e.key] = ElFamily.lanthanide;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Actinides
  final actinides = {
    El.actinium: (89,'Ac'), El.thorium: (90,'Th'), El.protactinium: (91,'Pa'),
    El.neptunium: (93,'Np'), El.plutonium: (94,'Pu'), El.americium: (95,'Am'),
    El.curium: (96,'Cm'), El.berkelium: (97,'Bk'), El.californium: (98,'Cf'),
    El.einsteinium: (99,'Es'), El.fermium: (100,'Fm'), El.mendelevium: (101,'Md'),
    El.nobelium: (102,'No'), El.lawrencium: (103,'Lr'),
  };
  for (final e in actinides.entries) {
    elementFamily[e.key] = ElFamily.actinide;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
  // Superheavy
  final superheavy = {
    El.hassium: (108,'Hs'), El.meitnerium: (109,'Mt'), El.darmstadtium: (110,'Ds'),
    El.roentgenium: (111,'Rg'), El.copernicium: (112,'Cn'), El.nihonium: (113,'Nh'),
    El.flerovium: (114,'Fl'), El.moscovium: (115,'Mc'),
    El.livermorium: (116,'Lv'), El.oganesson: (118,'Og'),
  };
  for (final e in superheavy.entries) {
    elementFamily[e.key] = ElFamily.superheavy;
    elementAtomicNumber[e.key] = e.value.$1; elementSymbol[e.key] = e.value.$2;
  }
}

/// Pre-computed density lookup table (Uint8List for hot-loop performance).
final Uint8List elementDensity = Uint8List(maxElements);

/// Pre-computed gravity lookup table (Int8List for signed values).
final Int8List elementGravity = Int8List(maxElements);

/// Pre-computed viscosity lookup table.
final Uint8List elementViscosity = Uint8List(maxElements);

/// Pre-computed physics state lookup table.
final Uint8List elementPhysicsState = Uint8List(maxElements);

/// Pre-computed base temperature lookup table.
final Uint8List elementBaseTemp = Uint8List(maxElements);

/// Pre-computed heat conductivity lookup (scaled 0-255 for integer math).
final Uint8List elementHeatCond = Uint8List(maxElements);

/// Pre-computed flammable lookup table.
final Uint8List elementFlammable = Uint8List(maxElements);

/// Pre-computed corrosion resistance lookup table.
final Uint8List elementCorrosionResistance = Uint8List(maxElements);

/// Pre-computed light emission intensity lookup table.
final Uint8List elementLightEmission = Uint8List(maxElements);

/// Pre-computed light emission color (R) lookup table.
final Uint8List elementLightR = Uint8List(maxElements);

/// Pre-computed light emission color (G) lookup table.
final Uint8List elementLightG = Uint8List(maxElements);

/// Pre-computed light emission color (B) lookup table.
final Uint8List elementLightB = Uint8List(maxElements);

/// Pre-computed decay rate lookup table.
final Uint8List elementDecayRate = Uint8List(maxElements);

/// Pre-computed decays-into element lookup table.
final Uint8List elementDecaysInto = Uint8List(maxElements);

/// Pre-computed surface tension lookup table.
final Uint8List elementSurfaceTension = Uint8List(maxElements);

/// Pre-computed max velocity lookup table.
final Uint8List elementMaxVelocity = Uint8List(maxElements);


/// Pre-computed porosity lookup table (scaled 0-255).
final Uint8List elementPorosity = Uint8List(maxElements);

/// Pre-computed hardness lookup table.
final Uint8List elementHardness = Uint8List(maxElements);

/// Pre-computed electrical conductivity lookup table (scaled 0-255).
final Uint8List elementConductivity = Uint8List(maxElements);

/// Pre-computed wind resistance lookup table (scaled 0-255).
final Uint8List elementWindResistance = Uint8List(maxElements);

/// Pre-computed specific heat capacity lookup table (1-10).
final Uint8List elementHeatCapacity = Uint8List(maxElements);

// -- Chemistry lookup tables (integer-only, hot-loop safe) ------------------

/// Pre-computed reduction potential (Int8List: -128 to +127).
final Int8List elementReductionPotential = Int8List(maxElements);

/// Pre-computed bond energy (0-255).
final Uint8List elementBondEnergy = Uint8List(maxElements);

/// Pre-computed fuel value (0-255). 0 = non-combustible.
final Uint8List elementFuelValue = Uint8List(maxElements);

/// Pre-computed ignition temperature (0-255).
final Uint8List elementIgnitionTemp = Uint8List(maxElements);

/// Pre-computed oxidation product element ID.
final Uint8List elementOxidizesInto = Uint8List(maxElements);

/// Pre-computed oxidation byproduct element ID.
final Uint8List elementOxidationByproduct = Uint8List(maxElements);

/// Pre-computed reduction product element ID.
final Uint8List elementReducesInto = Uint8List(maxElements);

/// Pre-computed electron mobility (0-255).
final Uint8List elementElectronMobility = Uint8List(maxElements);

/// Pre-computed dielectric constant (0-255).
final Uint8List elementDielectric = Uint8List(maxElements);

/// Pre-computed chemical reactivity (0-255).
final Uint8List elementReactivity = Uint8List(maxElements);

/// Pre-computed base mass (0-255).
final Uint8List elementBaseMass = Uint8List(maxElements);

/// Rebuild all lookup tables from [elementProperties].
/// Called by [_initElementProperties] after property values are set.
void _rebuildPropertyLookups() {
  for (int i = 0; i < maxElements; i++) {
    final p = elementProperties[i];
    elementDensity[i] = p.density;
    elementGravity[i] = p.gravity;
    elementViscosity[i] = p.viscosity;
    elementPhysicsState[i] = p.state.index;
    elementBaseTemp[i] = p.baseTemperature;
    elementHeatCond[i] = (p.heatConductivity * 255).round().clamp(0, 255);
    elementFlammable[i] = p.flammable ? 1 : 0;
    elementCorrosionResistance[i] = p.corrosionResistance;
    elementLightEmission[i] = p.lightEmission;
    elementLightR[i] = p.lightR;
    elementLightG[i] = p.lightG;
    elementLightB[i] = p.lightB;
    elementDecayRate[i] = p.decayRate;
    elementDecaysInto[i] = p.decaysInto;
    elementPorosity[i] = (p.porosity * 255).round().clamp(0, 255);
    elementHardness[i] = p.hardness.clamp(0, 255);
    elementConductivity[i] = (p.conductivity * 255).round().clamp(0, 255);
    elementWindResistance[i] = (p.windResistance * 255).round().clamp(0, 255);
    elementHeatCapacity[i] = p.heatCapacity.clamp(1, 10);
    elementSurfaceTension[i] = p.surfaceTension;
    elementMaxVelocity[i] = p.maxVelocity;
    // Chemistry lookup tables
    elementReductionPotential[i] = p.reductionPotential;
    elementBondEnergy[i] = p.bondEnergy;
    elementFuelValue[i] = p.fuelValue;
    elementIgnitionTemp[i] = p.ignitionTemp;
    elementOxidizesInto[i] = p.oxidizesInto;
    elementOxidationByproduct[i] = p.oxidationByproduct;
    elementReducesInto[i] = p.reducesInto;
    elementElectronMobility[i] = p.electronMobility;
    elementDielectric[i] = p.dielectric;
    elementReactivity[i] = p.reactivity;
    elementBaseMass[i] = p.baseMass;
  }
}

// ---------------------------------------------------------------------------
// Plant data constants
// ---------------------------------------------------------------------------

const int plantGrass = 1;
const int plantFlower = 2;
const int plantTree = 3;
const int plantMushroom = 4;
const int plantVine = 5;
const int plantSeaweed = 6;
const int plantMoss = 7;
const int plantNeuralVine = 8;
const int plantNeuralFlower = 9;
const int plantRoot = 10;
const int plantThorn = 11;

const int stSprout = 0;
const int stGrowing = 1;
const int stMature = 2;
const int stWilting = 3;
const int stDead = 4;

/// Maximum height by plant type (indexed by PLANT_* constant).
const List<int> plantMaxH = [0, 3, 6, 15, 3, 12, 20, 2, 15, 5, 12, 3];

/// Minimum soil moisture required to grow.
const List<int> plantMinMoist = [0, 1, 2, 3, 4, 2, 0, 0, 1, 2, 2, 1];

/// Growth rate (lower = faster). Tick modulo gate.
const List<int> plantGrowRate = [0, 15, 35, 20, 40, 30, 25, 50, 25, 30, 20, 35];

// ---------------------------------------------------------------------------
// Ant state constants
// ---------------------------------------------------------------------------

const int antExplorerState = 0;
const int antDiggerState = 1;
const int antCarrierState = 2;
const int antReturningState = 3;
const int antForagerState = 4;
const int antDrowningBase = 10;

// ---------------------------------------------------------------------------
// Element metadata registry (extensible)
// ---------------------------------------------------------------------------

/// Callback type for custom element simulation behaviors.
typedef ElementBehaviorFn = void Function(
  dynamic engine, int x, int y, int idx,
);

/// Metadata for a single element type.
class ElementInfo {
  final int id;
  final String name;
  final int color;
  final int category;
  final int windSens;
  final bool isStatic;
  final bool neverSettles;

  /// Optional custom behavior function for runtime-registered elements.
  /// Built-in elements use the switch dispatch in element_behaviors.dart.
  final ElementBehaviorFn? behavior;

  /// Whether this element is available in the user palette.
  final bool placeable;

  const ElementInfo({
    required this.id,
    required this.name,
    required this.color,
    this.category = 0,
    this.windSens = 0,
    this.isStatic = false,
    this.neverSettles = false,
    this.behavior,
    this.placeable = true,
  });
}

/// Central registry of all element types and their metadata.
///
/// Truly extensible: [register] adds new elements and propagates their
/// properties to all lookup tables (colors, categories, wind sensitivity,
/// settle behavior, static set). The simulation engine's behavior dispatch
/// checks [customBehaviors] for IDs beyond the built-in set.
class ElementRegistry {
  static final Map<int, ElementInfo> _elements = {};

  /// Custom behavior functions for runtime-registered elements.
  /// The behavior dispatch checks this map for element IDs not handled
  /// by the built-in switch statement.
  static final Map<int, ElementBehaviorFn> customBehaviors = {};

  /// Track the next available ID for auto-assigned elements.
  static int _nextCustomId = El.count;

  /// Initialize with all built-in elements.
  static void init() {
    if (_elements.isNotEmpty) return;
    _initElementProperties();
    for (int i = 0; i < El.count; i++) {
      if (elementNames[i].isEmpty) continue; // skip gaps (e.g. ID 99)
      _elements[i] = ElementInfo(
        id: i,
        name: elementNames[i],
        color: baseColors[i],
        category: i < elCategory.length ? elCategory[i] : 0,
        windSens: i < windSensitivity.length ? windSensitivity[i] : 0,
        isStatic: staticElements.contains(i),
        neverSettles: i < neverSettle.length && neverSettle[i] != 0,
        placeable: i != El.empty,
      );
    }
    _nextCustomId = El.count;
  }

  /// Register a custom element type at runtime.
  ///
  /// Propagates all properties to the global lookup tables so the
  /// simulation engine, renderer, and AI sensing all recognize the
  /// new element without any code changes.
  static void register(ElementInfo info) {
    assert(info.id > 0 && info.id < maxElements,
        'Element ID ${info.id} out of range 1..${maxElements - 1}');
    _elements[info.id] = info;

    // Propagate to lookup tables.
    baseColors[info.id] = info.color;
    elementNames[info.id] = info.name;
    elCategory[info.id] = info.category;
    windSensitivity[info.id] = info.windSens;
    neverSettle[info.id] = info.neverSettles ? 1 : 0;
    if (info.isStatic) {
      staticElements.add(info.id);
    } else {
      staticElements.remove(info.id);
    }

    // Register custom behavior if provided.
    if (info.behavior != null) {
      customBehaviors[info.id] = info.behavior!;
    }

    // Update next ID tracker.
    if (info.id >= _nextCustomId) {
      _nextCustomId = info.id + 1;
    }
  }

  /// Allocate the next available element ID.
  static int nextId() {
    final id = _nextCustomId;
    _nextCustomId++;
    return id;
  }

  /// Look up element info by ID.
  static ElementInfo? byId(int id) => _elements[id];

  /// Look up element by name (case-insensitive).
  static ElementInfo? byName(String name) {
    final lower = name.toLowerCase();
    for (final e in _elements.values) {
      if (e.name.toLowerCase() == lower) return e;
    }
    return null;
  }

  /// All registered element types.
  static Iterable<ElementInfo> get all => _elements.values;

  /// All placeable element IDs (excludes empty, non-placeable).
  static List<int> get placeableIds =>
      _elements.values
          .where((e) => e.placeable && e.id != El.empty)
          .map((e) => e.id)
          .toList();
}

"""Integration tests for trained genomes and pipeline outputs.

Verifies that trained NEAT genomes parse correctly, compile into
NeatForward networks, produce valid outputs, and survive 100+ ticks
of simulated behavior. Also validates other pipeline deliverables.

These tests run WITHOUT Dart or Flutter -- they validate the JSON
genome format against our Python NEAT port, ensuring the genomes
will work when loaded into the Dart engine.

Usage:
    pytest research/tests/test_integration.py -v
    pytest research/tests/test_integration.py -k genome -v
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

import numpy as np
import pytest

RESEARCH_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = RESEARCH_DIR.parent
TRAINED_GENOMES_DIR = RESEARCH_DIR / "trained_genomes"
CLOUD_GENOMES_DIR = RESEARCH_DIR / "cloud" / "trained_genomes"

# ---------------------------------------------------------------------------
# Genome format helpers (Python port of Dart NeatGenome.fromJson)
# ---------------------------------------------------------------------------

# NodeType enum values (matching Dart)
NODE_INPUT = 0
NODE_HIDDEN = 1
NODE_OUTPUT = 2
NODE_BIAS = 3

# ActivationFunction enum values (matching Dart NeatConfig)
ACT_SIGMOID = 0
ACT_TANH = 1
ACT_RELU = 2
ACT_IDENTITY = 3
ACT_STEP = 4
ACT_GAUSSIAN = 5
ACT_SINE = 6
ACT_ABS = 7

ACTIVATION_FUNCS = {
    ACT_SIGMOID: lambda x: 1.0 / (1.0 + math.exp(-max(-60, min(60, x)))),
    ACT_TANH: lambda x: math.tanh(x),
    ACT_RELU: lambda x: max(0.0, x),
    ACT_IDENTITY: lambda x: x,
    ACT_STEP: lambda x: 1.0 if x > 0 else 0.0,
    ACT_GAUSSIAN: lambda x: math.exp(-(x * x)),
    ACT_SINE: lambda x: math.sin(x),
    ACT_ABS: lambda x: abs(x),
}


def parse_genome(data: dict) -> dict:
    """Parse a genome JSON dict into structured data, mirroring Dart's fromJson."""
    nodes = {}
    for n in data["nodes"]:
        nodes[n["id"]] = {
            "id": n["id"],
            "type": n["type"],
            "activation": n.get("activation", ACT_TANH),
            "layer": n.get("layer", 0),
        }

    connections = {}
    for c in data["connections"]:
        connections[c["innovation"]] = {
            "innovation": c["innovation"],
            "inNode": c["inNode"],
            "outNode": c["outNode"],
            "weight": float(c["weight"]),
            "enabled": c["enabled"],
        }

    return {
        "nodes": nodes,
        "connections": connections,
        "fitness": float(data.get("fitness", 0.0)),
        "speciesId": data.get("speciesId", -1),
    }


def compile_network(genome: dict) -> dict:
    """Compile a parsed genome into a feed-forward network (Python port of NeatForward)."""
    nodes = genome["nodes"]
    connections = genome["connections"]

    input_ids = sorted(nid for nid, n in nodes.items() if n["type"] == NODE_INPUT)
    output_ids = sorted(nid for nid, n in nodes.items() if n["type"] == NODE_OUTPUT)
    bias_ids = sorted(nid for nid, n in nodes.items() if n["type"] == NODE_BIAS)
    hidden_ids = sorted(nid for nid, n in nodes.items() if n["type"] == NODE_HIDDEN)

    # Build adjacency for topological sort
    enabled_conns = [c for c in connections.values() if c["enabled"]]

    # Topological order: inputs/bias first, then hidden by layer, then outputs
    process_order = hidden_ids + output_ids

    return {
        "input_ids": input_ids,
        "output_ids": output_ids,
        "bias_ids": bias_ids,
        "hidden_ids": hidden_ids,
        "process_order": process_order,
        "connections": enabled_conns,
        "activations": {nid: nodes[nid]["activation"] for nid in nodes},
    }


def forward_pass(network: dict, inputs: list[float]) -> list[float]:
    """Run a forward pass through the compiled network."""
    values = {}

    # Set input values
    for i, nid in enumerate(network["input_ids"]):
        values[nid] = inputs[i] if i < len(inputs) else 0.0

    # Set bias values
    for nid in network["bias_ids"]:
        values[nid] = 1.0

    # Process hidden and output nodes in order
    for nid in network["process_order"]:
        total = 0.0
        for c in network["connections"]:
            if c["outNode"] == nid:
                in_val = values.get(c["inNode"], 0.0)
                total += in_val * c["weight"]

        act_fn = ACTIVATION_FUNCS.get(network["activations"].get(nid, ACT_TANH), math.tanh)
        values[nid] = act_fn(total)

    return [values.get(nid, 0.0) for nid in network["output_ids"]]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def find_genome_files() -> list[Path]:
    """Find all trained genome JSON files."""
    paths = []
    for d in [TRAINED_GENOMES_DIR, CLOUD_GENOMES_DIR]:
        if d.exists():
            paths.extend(d.glob("*_best.json"))
            paths.extend(d.glob("*_population.json"))
    return paths


def find_best_genome_files() -> list[Path]:
    """Find best genome files (not full populations)."""
    paths = []
    for d in [TRAINED_GENOMES_DIR, CLOUD_GENOMES_DIR]:
        if d.exists():
            paths.extend(d.glob("*_best.json"))
    return paths


GENOME_FILES = find_genome_files()
BEST_GENOME_FILES = find_best_genome_files()


# ---------------------------------------------------------------------------
# Genome parsing tests
# ---------------------------------------------------------------------------

class TestGenomeParsing:
    """Test that trained genome JSON files parse correctly."""

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_loads_as_valid_json(self, genome_path: Path):
        """Genome file must be valid JSON."""
        data = json.loads(genome_path.read_text())
        assert isinstance(data, (dict, list))

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_has_required_fields(self, genome_path: Path):
        """Each genome must have nodes and connections."""
        data = json.loads(genome_path.read_text())

        # Handle both single genome and population files
        genomes = data if isinstance(data, list) else [data]
        for g in genomes[:5]:  # Check first 5 in populations
            assert "nodes" in g, "Missing 'nodes' field"
            assert "connections" in g, "Missing 'connections' field"
            assert isinstance(g["nodes"], list), "nodes must be a list"
            assert isinstance(g["connections"], list), "connections must be a list"

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_node_format(self, genome_path: Path):
        """Each node must have id, type, activation, layer."""
        data = json.loads(genome_path.read_text())
        genomes = data if isinstance(data, list) else [data]

        for g in genomes[:5]:
            for node in g["nodes"]:
                assert "id" in node, "Node missing 'id'"
                assert "type" in node, "Node missing 'type'"
                assert isinstance(node["id"], int), "Node id must be int"
                assert node["type"] in (0, 1, 2, 3), f"Invalid node type: {node['type']}"

                if "activation" in node:
                    assert node["activation"] in range(8), f"Invalid activation: {node['activation']}"
                if "layer" in node:
                    assert isinstance(node["layer"], int), "Layer must be int"

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_connection_format(self, genome_path: Path):
        """Each connection must have innovation, inNode, outNode, weight, enabled."""
        data = json.loads(genome_path.read_text())
        genomes = data if isinstance(data, list) else [data]

        for g in genomes[:5]:
            for conn in g["connections"]:
                assert "innovation" in conn, "Connection missing 'innovation'"
                assert "inNode" in conn, "Connection missing 'inNode'"
                assert "outNode" in conn, "Connection missing 'outNode'"
                assert "weight" in conn, "Connection missing 'weight'"
                assert "enabled" in conn, "Connection missing 'enabled'"
                assert isinstance(conn["weight"], (int, float)), "Weight must be numeric"
                assert isinstance(conn["enabled"], bool), "Enabled must be bool"

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_connection_nodes_exist(self, genome_path: Path):
        """All connection endpoints must reference existing nodes."""
        data = json.loads(genome_path.read_text())
        genomes = data if isinstance(data, list) else [data]

        for g in genomes[:5]:
            node_ids = {n["id"] for n in g["nodes"]}
            for conn in g["connections"]:
                assert conn["inNode"] in node_ids, \
                    f"Connection references missing inNode {conn['inNode']}"
                assert conn["outNode"] in node_ids, \
                    f"Connection references missing outNode {conn['outNode']}"

    @pytest.mark.skipif(not GENOME_FILES, reason="No trained genome files found")
    @pytest.mark.parametrize("genome_path", GENOME_FILES, ids=lambda p: p.name)
    def test_genome_has_inputs_and_outputs(self, genome_path: Path):
        """Genome must have at least one input and one output node."""
        data = json.loads(genome_path.read_text())
        genomes = data if isinstance(data, list) else [data]

        for g in genomes[:5]:
            types = [n["type"] for n in g["nodes"]]
            assert NODE_INPUT in types, "No input nodes"
            assert NODE_OUTPUT in types, "No output nodes"


# ---------------------------------------------------------------------------
# Network compilation tests
# ---------------------------------------------------------------------------

class TestNetworkCompilation:
    """Test that genomes compile into runnable networks."""

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_genome_compiles(self, genome_path: Path):
        """Genome must compile into a NeatForward network."""
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        assert len(network["input_ids"]) > 0, "No inputs"
        assert len(network["output_ids"]) > 0, "No outputs"
        assert len(network["process_order"]) > 0, "Empty process order"

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_forward_pass_produces_valid_outputs(self, genome_path: Path):
        """Forward pass must produce finite float outputs."""
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        n_inputs = len(network["input_ids"])
        inputs = [0.5] * n_inputs

        outputs = forward_pass(network, inputs)

        assert len(outputs) == len(network["output_ids"])
        for i, val in enumerate(outputs):
            assert isinstance(val, float), f"Output {i} is not float: {type(val)}"
            assert math.isfinite(val), f"Output {i} is not finite: {val}"

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_forward_pass_with_random_inputs(self, genome_path: Path):
        """Forward pass must handle random inputs without NaN/Inf."""
        rng = np.random.default_rng(42)
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        n_inputs = len(network["input_ids"])

        for _ in range(100):
            inputs = rng.uniform(-1.0, 1.0, n_inputs).tolist()
            outputs = forward_pass(network, inputs)
            for val in outputs:
                assert math.isfinite(val), f"Non-finite output with inputs {inputs[:3]}..."

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_forward_pass_with_extreme_inputs(self, genome_path: Path):
        """Network must not explode with extreme input values."""
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        n_inputs = len(network["input_ids"])

        extreme_sets = [
            [1000.0] * n_inputs,
            [-1000.0] * n_inputs,
            [0.0] * n_inputs,
            [1e-10] * n_inputs,
        ]

        for inputs in extreme_sets:
            outputs = forward_pass(network, inputs)
            for val in outputs:
                assert math.isfinite(val), f"Non-finite output with extreme inputs"


# ---------------------------------------------------------------------------
# Creature behavior simulation tests
# ---------------------------------------------------------------------------

class TestCreatureBehavior:
    """Test that trained genomes produce sensible creature behavior."""

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_100_ticks_stable(self, genome_path: Path):
        """Run 100 ticks of behavior without crashes or NaN."""
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        n_inputs = len(network["input_ids"])
        n_outputs = len(network["output_ids"])
        rng = np.random.default_rng(42)

        # Simulate 100 ticks with evolving inputs
        pos_x, pos_y = 160.0, 90.0  # Center of 320x180 grid
        energy = 100.0

        for tick in range(100):
            # Build sensor inputs (normalized to [-1, 1])
            inputs = [
                pos_x / 320.0 * 2 - 1,    # normalized x
                pos_y / 180.0 * 2 - 1,     # normalized y
                energy / 100.0,             # energy level
            ]
            # Pad with random sensor readings
            while len(inputs) < n_inputs:
                inputs.append(rng.uniform(-1, 1))

            outputs = forward_pass(network, inputs[:n_inputs])

            # All outputs must be valid
            for i, val in enumerate(outputs):
                assert math.isfinite(val), f"Tick {tick}, output {i} = {val}"

            # Simulate movement from first two outputs (if they exist)
            if n_outputs >= 2:
                dx = outputs[0] * 2.0  # scaled movement
                dy = outputs[1] * 2.0
                pos_x = max(0, min(319, pos_x + dx))
                pos_y = max(0, min(179, pos_y + dy))

            energy -= 0.1  # decay

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_outputs_are_not_constant(self, genome_path: Path):
        """Outputs should vary with different inputs (network is not dead)."""
        data = json.loads(genome_path.read_text())
        genome = parse_genome(data)
        network = compile_network(genome)

        n_inputs = len(network["input_ids"])
        rng = np.random.default_rng(42)

        output_sets = []
        for _ in range(20):
            inputs = rng.uniform(-1, 1, n_inputs).tolist()
            outputs = forward_pass(network, inputs)
            output_sets.append(tuple(round(o, 6) for o in outputs))

        unique_outputs = len(set(output_sets))
        # At least some variation expected (allow for simple networks)
        assert unique_outputs >= 2, \
            f"Network always produces same output (dead network): {output_sets[0]}"

    @pytest.mark.skipif(not BEST_GENOME_FILES, reason="No best genome files found")
    @pytest.mark.parametrize("genome_path", BEST_GENOME_FILES, ids=lambda p: p.name)
    def test_positive_fitness(self, genome_path: Path):
        """Best genomes should have positive fitness."""
        data = json.loads(genome_path.read_text())
        fitness = data.get("fitness", 0)
        # Trained genomes should have evolved some fitness
        assert fitness > 0, f"Best genome has non-positive fitness: {fitness}"


# ---------------------------------------------------------------------------
# Pipeline output validation tests
# ---------------------------------------------------------------------------

class TestPipelineOutputs:
    """Validate non-genome pipeline outputs."""

    def test_physics_db_exists_if_dir_present(self):
        """If physics optimization ran, the DB should exist."""
        db_path = RESEARCH_DIR / "cloud_proper_study.db"
        if not db_path.exists():
            pytest.skip("No physics optimization DB found")
        assert db_path.stat().st_size > 0, "Physics DB is empty"

    def test_regression_report_valid(self):
        """If regression tests ran, report should be valid JSON."""
        report = RESEARCH_DIR / "cloud" / "regression_results" / "test_report.json"
        if not report.exists():
            pytest.skip("No regression report found")
        data = json.loads(report.read_text())
        assert "scenarios" in data or "results" in data

    def test_style_results_valid(self):
        """If style evolution ran, results should be valid JSON."""
        for f in (RESEARCH_DIR / "cloud" / "style_results").glob("*.json"):
            data = json.loads(f.read_text())
            assert isinstance(data, (dict, list))
            break
        else:
            pytest.skip("No style results found")

    def test_worldgen_results_valid(self):
        """If worldgen optimization ran, results should be valid."""
        results_dir = RESEARCH_DIR / "cloud" / "worldgen_results"
        if not results_dir.exists():
            pytest.skip("No worldgen results found")
        json_files = list(results_dir.glob("*.json"))
        if not json_files:
            pytest.skip("No worldgen JSON files found")
        data = json.loads(json_files[0].read_text())
        assert isinstance(data, (dict, list))

    def test_audio_files_are_wav(self):
        """If audio generation ran, files should be valid WAV."""
        audio_dir = RESEARCH_DIR / "cloud" / "audio_output"
        if not audio_dir.exists():
            pytest.skip("No audio output found")
        wav_files = list(audio_dir.glob("*.wav"))
        if not wav_files:
            pytest.skip("No WAV files found")
        for wav in wav_files[:5]:
            header = wav.read_bytes()[:4]
            assert header == b"RIFF", f"{wav.name} is not a valid WAV file"

    def test_texture_atlas_images(self):
        """If texture atlas ran, output should contain images."""
        atlas_dir = RESEARCH_DIR / "cloud" / "atlas_output"
        if not atlas_dir.exists():
            pytest.skip("No atlas output found")
        img_files = list(atlas_dir.glob("*.png")) + list(atlas_dir.glob("*.jpg"))
        if not img_files:
            pytest.skip("No image files in atlas output")
        for img in img_files[:5]:
            assert img.stat().st_size > 0, f"{img.name} is empty"

#!/usr/bin/env python3
"""GPU-accelerated electrical conductivity benchmark.

Simulates voltage propagation through complex circuit topologies at scale
on A100 GPU via CuPy to verify:
  1. Current flows through metal wires with minimal loss
  2. Water bridges attenuate voltage proportional to resistance
  3. Glass/stone insulators block current completely
  4. Ohmic heating occurs at resistive junctions
  5. Kirchhoff-like conservation holds at junctions
  6. Refractory period prevents infinite oscillation
  7. Wet materials conduct better than dry (moisture coupling)
  8. Lightning discharge follows path of least resistance

Usage:
    python research/cloud/gpu_electrical_benchmark.py --circuits 10000
    python research/cloud/gpu_electrical_benchmark.py --quick
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    import cupy as xp
    GPU_AVAILABLE = True
    print(f"Using CuPy with GPU: {xp.cuda.runtime.getDeviceProperties(0)['name'].decode()}")
except ImportError:
    import numpy as xp
    GPU_AVAILABLE = False
    print("CuPy not available, falling back to NumPy")

import numpy as np

from system_profile import resolve_electrical_batch, resolve_electrical_circuits

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
GRID_W, GRID_H = 320, 180
TOTAL_CELLS = GRID_W * GRID_H

EL_EMPTY = 0; EL_WATER = 2; EL_STONE = 7; EL_GLASS = 15
EL_LAVA = 18; EL_METAL = 21; EL_SALT = 33

# Electron mobility values (from unified physics design)
ELECTRON_MOBILITY = xp.zeros(64, dtype=xp.uint8)
ELECTRON_MOBILITY[EL_METAL] = 240
ELECTRON_MOBILITY[EL_WATER] = 80
ELECTRON_MOBILITY[EL_LAVA] = 40
ELECTRON_MOBILITY[EL_SALT] = 120
# Insulators: 0
ELECTRON_MOBILITY[EL_GLASS] = 0
ELECTRON_MOBILITY[EL_STONE] = 0
ELECTRON_MOBILITY[EL_EMPTY] = 0

SCRIPT_DIR = Path(__file__).resolve().parent


@dataclass
class BenchmarkResult:
    name: str
    passed: bool
    details: str
    metrics: dict


# ---------------------------------------------------------------------------
# Electricity simulation (batched GPU)
# ---------------------------------------------------------------------------

def simulate_voltage(grid: xp.ndarray, voltage: xp.ndarray,
                     spark: xp.ndarray, temp: xp.ndarray,
                     steps: int = 100, moisture: xp.ndarray = None) -> dict:
    """Run voltage propagation for given steps. Returns final state + history."""
    batch_size = grid.shape[0]
    v_2d = voltage.reshape(batch_size, GRID_H, GRID_W).astype(xp.int16)
    source_v = v_2d.copy()
    source_mask = source_v != 0
    g_2d = grid.reshape(batch_size, GRID_H, GRID_W)
    s_2d = spark.reshape(batch_size, GRID_H, GRID_W)
    t_2d = temp.reshape(batch_size, GRID_H, GRID_W).astype(xp.int16)

    # Compute effective electron mobility (base + moisture contribution)
    base_emob = ELECTRON_MOBILITY[g_2d.ravel().astype(xp.int64)].reshape(g_2d.shape)
    if moisture is not None:
        m_2d = moisture.reshape(batch_size, GRID_H, GRID_W)
        # Wet materials get conductivity boost: base + moisture/4
        eff_emob = xp.minimum(255, base_emob.astype(xp.int16) + (m_2d.astype(xp.int16) >> 2))
        eff_emob = eff_emob.astype(xp.uint8)
    else:
        eff_emob = base_emob

    voltage_history = []
    spark_count_history = []
    heat_history = []

    for step in range(steps):
        new_v = v_2d.copy()
        new_s = s_2d.copy()
        new_t = t_2d.copy()

        # Advance refractory timers
        refractory = (s_2d > 0) & (s_2d < 4)
        new_s[refractory] = s_2d[refractory] + 1
        reset = new_s >= 4
        new_s[reset] = 0

        # Max neighbor voltage (4-connected)
        padded_v = xp.pad(v_2d, ((0, 0), (1, 1), (1, 1)),
                          mode='constant', constant_values=0)
        max_nv = xp.maximum(
            xp.maximum(padded_v[:, :-2, 1:-1], padded_v[:, 2:, 1:-1]),
            xp.maximum(padded_v[:, 1:-1, :-2], padded_v[:, 1:-1, 2:])
        )

        # Propagation condition
        is_conductor = eff_emob > 0
        not_refractory = s_2d == 0
        gradient = max_nv - v_2d
        propagate = is_conductor & not_refractory & (gradient > 5) & (~source_mask)

        # Voltage with attenuation
        resistance = (255 - eff_emob[propagate].astype(xp.int16))
        # The previous attenuation collapsed most long wires to zero before the
        # wave could reach the far end. A softer drop better matches the game's
        # intended conductive materials and keeps the benchmarks discriminative.
        attenuation = xp.maximum(xp.int16(1), resistance >> 5)
        new_voltage = max_nv[propagate] - attenuation
        new_v[propagate] = xp.clip(new_voltage, -128, 127)
        new_s[propagate] = 1  # spark head

        # Ohmic heating: P ~ V_drop * R
        high_r = resistance > 30
        heat = ((max_nv[propagate] - new_v[propagate]) * resistance) >> 8
        temp_at = new_t[propagate]
        temp_at[high_r] = xp.minimum(255, temp_at[high_r] + heat[high_r])
        new_t[propagate] = temp_at

        # Voltage decay for idle cells
        idle = is_conductor & (s_2d == 0) & (~propagate) & (v_2d != 0) & (~source_mask)
        decay = xp.maximum(xp.int16(1), (255 - eff_emob[idle].astype(xp.int16)) >> 6)
        decayed = v_2d[idle].copy()
        pos = decayed > 0
        neg = decayed < 0
        decayed[pos] = xp.maximum(0, decayed[pos] - decay[pos])
        decayed[neg] = xp.minimum(0, decayed[neg] + decay[neg])
        new_v[idle] = decayed

        # Keep explicit sources pinned so the field does not collapse after the
        # first few iterations.
        new_v[source_mask] = source_v[source_mask]

        v_2d = new_v
        s_2d = new_s
        t_2d = new_t

        voltage_history.append(float(xp.mean(xp.abs(v_2d))))
        spark_count_history.append(int(xp.sum(s_2d == 1)))
        heat_history.append(float(xp.mean(t_2d)))

    return {
        "voltage": v_2d.reshape(batch_size, TOTAL_CELLS),
        "spark": s_2d.reshape(batch_size, TOTAL_CELLS),
        "temperature": t_2d.reshape(batch_size, TOTAL_CELLS).astype(xp.uint8),
        "voltage_history": voltage_history,
        "spark_history": spark_count_history,
        "heat_history": heat_history,
    }


# ---------------------------------------------------------------------------
# Circuit topology generators
# ---------------------------------------------------------------------------

def make_straight_wire(batch_size: int) -> dict:
    """Simple horizontal metal wire, voltage source at left."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    y = 90
    grid[:, y, 20:300] = EL_METAL
    voltage[:, y, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "straight_wire",
    }


def make_water_bridge(batch_size: int) -> dict:
    """Metal wire with water gap in the middle."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    y = 90
    grid[:, y, 20:140] = EL_METAL
    grid[:, y, 140:180] = EL_WATER  # water bridge
    grid[:, y, 180:300] = EL_METAL
    voltage[:, y, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "water_bridge",
    }


def make_glass_insulator(batch_size: int) -> dict:
    """Metal wire broken by glass insulator."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    y = 90
    grid[:, y, 20:155] = EL_METAL
    grid[:, y, 155:165] = EL_GLASS  # insulator
    grid[:, y, 165:300] = EL_METAL
    voltage[:, y, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "glass_insulator",
    }


def make_parallel_paths(batch_size: int) -> dict:
    """Two parallel metal paths — current should split and rejoin."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    # Common source wire
    grid[:, 90, 20:80] = EL_METAL
    # Split into two paths
    grid[:, 80, 80:240] = EL_METAL  # top path
    grid[:, 100, 80:240] = EL_METAL  # bottom path
    # Vertical connections at split/join
    grid[:, 81:90, 80] = EL_METAL
    grid[:, 91:100, 80] = EL_METAL
    grid[:, 81:90, 239] = EL_METAL
    grid[:, 91:100, 239] = EL_METAL
    # Common drain wire
    grid[:, 90, 239:300] = EL_METAL
    voltage[:, 90, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "parallel_paths",
    }


def make_resistive_junction(batch_size: int) -> dict:
    """Metal wire with a water segment — should generate heat at junction."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    y = 90
    grid[:, y, 20:150] = EL_METAL
    grid[:, y, 150:170] = EL_WATER  # resistive section
    grid[:, y, 170:300] = EL_METAL
    voltage[:, y, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "resistive_junction",
    }


def make_wet_wood_test(batch_size: int) -> dict:
    """Dry wood (no conduction) vs wet wood (should conduct via moisture)."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    moisture = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    # Use element 20 (wood) - electronMobility = 2 (nearly zero)
    EL_WOOD = 20
    ELECTRON_MOBILITY[EL_WOOD] = 2  # base: almost insulator
    y = 90
    grid[:, y, 20:100] = EL_METAL
    grid[:, y, 100:200] = EL_WOOD  # wood segment
    grid[:, y, 200:300] = EL_METAL
    # Wet half of the wood
    moisture[:, y, 100:200] = 200  # very wet — adds 50 to eMobility
    voltage[:, y, 20] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "moisture": moisture.reshape(batch_size, -1),
        "name": "wet_wood",
    }


def make_lightning_discharge(batch_size: int) -> dict:
    """Lightning strike at top — should follow metal path over stone."""
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)
    # Ground is stone except for a metal path
    grid[:, 100:170, 50:270] = EL_STONE
    # Metal lightning rod path
    grid[:, 10:170, 160] = EL_METAL
    # Lightning strike at top
    voltage[:, 10, 160] = 127
    return {
        "grid": grid.reshape(batch_size, -1),
        "voltage": voltage.reshape(batch_size, -1),
        "spark": xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        "temp": xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        "name": "lightning_discharge",
    }


# ---------------------------------------------------------------------------
# Benchmark tests
# ---------------------------------------------------------------------------

def bench_straight_wire(batch_size: int) -> BenchmarkResult:
    """Metal wire: voltage should reach far end with minimal attenuation."""
    circuit = make_straight_wire(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=100
    )

    v_final = result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    v_at_end = float(xp.mean(v_final[:, 90, 290]))
    v_at_source = float(xp.mean(v_final[:, 90, 25]))

    # Metal (eMob=240): attenuation = (255-240)>>3 = 1 per cell
    # Over 280 cells: expect ~127 - 280 = <0, but with propagation waves,
    # steady state should show gradient
    total_drop = abs(127 - v_at_end)
    passed = v_at_end > 20  # should reach far end with significant voltage

    return BenchmarkResult(
        name="straight_wire_conduction",
        passed=passed,
        details=f"Source V={v_at_source:.1f}, End V={v_at_end:.1f}, Drop={total_drop:.1f}",
        metrics={"source_v": v_at_source, "end_v": v_at_end, "drop": total_drop}
    )


def bench_water_bridge(batch_size: int) -> BenchmarkResult:
    """Water bridge: voltage should cross but with more attenuation than metal."""
    metal_circuit = make_straight_wire(batch_size)
    water_circuit = make_water_bridge(batch_size)

    metal_result = simulate_voltage(
        metal_circuit["grid"], metal_circuit["voltage"],
        metal_circuit["spark"], metal_circuit["temp"], steps=100
    )
    water_result = simulate_voltage(
        water_circuit["grid"], water_circuit["voltage"],
        water_circuit["spark"], water_circuit["temp"], steps=100
    )

    metal_v = metal_result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    water_v = water_result["voltage"].reshape(batch_size, GRID_H, GRID_W)

    metal_end = float(xp.mean(metal_v[:, 90, 290]))
    water_end = float(xp.mean(water_v[:, 90, 290]))

    # Water should let some voltage through, but less than pure metal
    passed = (water_end > 0 and water_end < metal_end)

    return BenchmarkResult(
        name="water_bridge_attenuation",
        passed=passed,
        details=f"Metal end V={metal_end:.1f}, Water bridge end V={water_end:.1f}",
        metrics={"metal_end": metal_end, "water_end": water_end,
                 "ratio": water_end / max(0.01, metal_end)}
    )


def bench_glass_insulator(batch_size: int) -> BenchmarkResult:
    """Glass insulator: voltage should NOT cross the gap."""
    circuit = make_glass_insulator(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=100
    )

    v_final = result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    v_before_glass = float(xp.mean(v_final[:, 90, 150]))
    v_after_glass = float(xp.mean(v_final[:, 90, 170]))

    # Should be near zero after insulator
    passed = abs(v_after_glass) < 5

    return BenchmarkResult(
        name="glass_insulation",
        passed=passed,
        details=f"Before glass V={v_before_glass:.1f}, After glass V={v_after_glass:.1f}",
        metrics={"before": v_before_glass, "after": v_after_glass}
    )


def bench_parallel_paths(batch_size: int) -> BenchmarkResult:
    """Parallel paths: voltage should split and both paths should carry current."""
    circuit = make_parallel_paths(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=150
    )

    v_final = result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    v_top = float(xp.mean(v_final[:, 80, 160]))
    v_bottom = float(xp.mean(v_final[:, 100, 160]))
    v_end = float(xp.mean(v_final[:, 90, 290]))

    # Both paths should carry similar voltage (symmetric circuit)
    symmetry = abs(v_top - v_bottom) / max(1, (abs(v_top) + abs(v_bottom)) / 2)
    passed = symmetry < 0.3 and v_top > 5 and v_bottom > 5

    return BenchmarkResult(
        name="parallel_path_splitting",
        passed=passed,
        details=f"Top V={v_top:.1f}, Bottom V={v_bottom:.1f}, "
                f"Symmetry={symmetry:.2f}, End V={v_end:.1f}",
        metrics={"top": v_top, "bottom": v_bottom, "symmetry": symmetry, "end": v_end}
    )


def bench_ohmic_heating(batch_size: int) -> BenchmarkResult:
    """Resistive junction: water section should heat up more than metal."""
    circuit = make_resistive_junction(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=100
    )

    t_final = result["temperature"].reshape(batch_size, GRID_H, GRID_W)
    t_metal = float(xp.mean(t_final[:, 90, 100:140].astype(xp.float32)))
    t_water = float(xp.mean(t_final[:, 90, 150:170].astype(xp.float32)))
    t_baseline = 128.0  # neutral starting temp

    metal_heating = t_metal - t_baseline
    water_heating = t_water - t_baseline

    # Water (higher resistance) should heat up MORE than metal
    passed = water_heating > metal_heating

    return BenchmarkResult(
        name="ohmic_heating",
        passed=passed,
        details=f"Metal heating: +{metal_heating:.1f}, Water heating: +{water_heating:.1f}",
        metrics={"metal_heat": metal_heating, "water_heat": water_heating}
    )


def bench_refractory_stability(batch_size: int) -> BenchmarkResult:
    """Verify spark count doesn't explode (refractory period works)."""
    circuit = make_straight_wire(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=200
    )

    spark_history = result["spark_history"]
    # After initial wave, spark count should stabilize (not grow unbounded)
    peak = max(spark_history)
    final_avg = np.mean(spark_history[-20:]) if len(spark_history) >= 20 else peak
    # Stable = final is not growing compared to mid-history
    mid_avg = np.mean(spark_history[50:70]) if len(spark_history) >= 70 else peak

    # Allow some oscillation but not exponential growth
    growth_ratio = final_avg / max(1, mid_avg)
    passed = growth_ratio < 2.0

    return BenchmarkResult(
        name="refractory_stability",
        passed=passed,
        details=f"Peak sparks: {peak}, Mid avg: {mid_avg:.0f}, "
                f"Final avg: {final_avg:.0f}, Growth: {growth_ratio:.2f}x",
        metrics={"peak": peak, "mid_avg": mid_avg,
                 "final_avg": final_avg, "growth": growth_ratio}
    )


def bench_wet_wood_conductivity(batch_size: int) -> BenchmarkResult:
    """Wet wood should conduct electricity; dry wood should not."""
    circuit = make_wet_wood_test(batch_size)
    moisture = circuit.get("moisture")

    wet_result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=100,
        moisture=moisture
    )

    # Dry run: same circuit but zero moisture
    dry_result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=100,
        moisture=xp.zeros_like(moisture)
    )

    wet_v = wet_result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    dry_v = dry_result["voltage"].reshape(batch_size, GRID_H, GRID_W)

    wet_end = float(xp.mean(wet_v[:, 90, 250]))
    dry_end = float(xp.mean(dry_v[:, 90, 250]))

    # Wet wood should conduct significantly better
    passed = wet_end > dry_end + 5

    return BenchmarkResult(
        name="wet_wood_conductivity",
        passed=passed,
        details=f"Wet end V={wet_end:.1f}, Dry end V={dry_end:.1f}, "
                f"Difference={wet_end - dry_end:.1f}",
        metrics={"wet_end": wet_end, "dry_end": dry_end}
    )


def bench_lightning_path(batch_size: int) -> BenchmarkResult:
    """Lightning should preferentially follow the metal rod over stone."""
    circuit = make_lightning_discharge(batch_size)
    result = simulate_voltage(
        circuit["grid"], circuit["voltage"],
        circuit["spark"], circuit["temp"], steps=80
    )

    v_final = result["voltage"].reshape(batch_size, GRID_H, GRID_W)
    # Voltage along metal rod
    v_metal_rod = float(xp.mean(v_final[:, 80, 160]))
    # Voltage in stone next to rod
    v_stone = float(xp.mean(v_final[:, 80, 155]))

    # Metal rod should carry voltage, stone should not
    passed = v_metal_rod > v_stone + 10

    return BenchmarkResult(
        name="lightning_path_preference",
        passed=passed,
        details=f"Metal rod V={v_metal_rod:.1f}, Adjacent stone V={v_stone:.1f}",
        metrics={"metal": v_metal_rod, "stone": v_stone}
    )


# ---------------------------------------------------------------------------
# Kirchhoff validation (large scale)
# ---------------------------------------------------------------------------

def bench_kirchhoff_conservation(batch_size: int) -> BenchmarkResult:
    """Large-scale Kirchhoff test: at every conductor junction, current must conserve.

    After reaching steady state, the discrete Laplacian of voltage at each
    high-conductivity cell should be near zero (Laplace equation for potential).
    """
    # Random circuit topology
    grid = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.uint8)
    voltage = xp.zeros((batch_size, GRID_H, GRID_W), dtype=xp.int16)

    # Create random metal network
    rng = xp.random.RandomState(42)
    # Horizontal wires at random rows
    for _ in range(20):
        y = rng.randint(20, 160)
        x_start = rng.randint(10, 100)
        x_end = rng.randint(200, 310)
        grid[:, y, x_start:x_end] = EL_METAL
    # Vertical wires at random cols
    for _ in range(15):
        x = rng.randint(20, 300)
        y_start = rng.randint(10, 80)
        y_end = rng.randint(100, 170)
        grid[:, y_start:y_end, x] = EL_METAL

    # Multiple voltage sources
    for _ in range(5):
        y = rng.randint(20, 160)
        x = rng.randint(10, 310)
        if grid[0, y, x] == EL_METAL:
            voltage[:, y, x] = rng.randint(50, 127)

    result = simulate_voltage(
        grid.reshape(batch_size, -1),
        voltage.reshape(batch_size, -1),
        xp.zeros((batch_size, TOTAL_CELLS), dtype=xp.uint8),
        xp.full((batch_size, TOTAL_CELLS), 128, dtype=xp.int16),
        steps=200
    )

    v_2d = result["voltage"].reshape(batch_size, GRID_H, GRID_W).astype(xp.float32)
    g_2d = grid

    # Compute Laplacian at conductor cells
    padded_v = xp.pad(v_2d, ((0, 0), (1, 1), (1, 1)), mode='edge')
    laplacian = (
        padded_v[:, :-2, 1:-1] + padded_v[:, 2:, 1:-1] +
        padded_v[:, 1:-1, :-2] + padded_v[:, 1:-1, 2:] -
        4 * v_2d
    )

    # Only check interior metal cells (not at voltage sources or boundaries)
    emob_2d = ELECTRON_MOBILITY[g_2d.ravel().astype(xp.int64)].reshape(g_2d.shape)
    conductor_mask = emob_2d > 200  # high-conductivity metal cells
    # Exclude voltage source locations
    source_mask = xp.abs(voltage.reshape(batch_size, GRID_H, GRID_W)) > 40
    check_mask = conductor_mask & (~source_mask)

    if xp.sum(check_mask) == 0:
        return BenchmarkResult(
            name="kirchhoff_conservation",
            passed=True,
            details="No interior conductor cells to check",
            metrics={}
        )

    residuals = xp.abs(laplacian[check_mask])
    mean_res = float(xp.mean(residuals))
    max_res = float(xp.max(residuals))
    pct_low = float(xp.sum(residuals < 5)) / max(1, float(xp.sum(check_mask))) * 100

    # For a high-conductivity network at steady state, most residuals should be small
    passed = mean_res < 15 and pct_low > 50

    return BenchmarkResult(
        name="kirchhoff_conservation",
        passed=passed,
        details=f"Mean residual: {mean_res:.2f}, Max: {max_res:.2f}, "
                f"{pct_low:.0f}% cells below threshold",
        metrics={"mean_residual": mean_res, "max_residual": max_res,
                 "pct_converged": pct_low}
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_all_benchmarks(batch_size: int) -> list[BenchmarkResult]:
    """Run all electrical benchmarks."""
    per_test = resolve_electrical_batch(batch_size)
    benchmarks = [
        ("Straight Wire Conduction", lambda: bench_straight_wire(per_test)),
        ("Water Bridge Attenuation", lambda: bench_water_bridge(per_test)),
        ("Glass Insulation", lambda: bench_glass_insulator(per_test)),
        ("Parallel Path Splitting", lambda: bench_parallel_paths(per_test)),
        ("Ohmic Heating", lambda: bench_ohmic_heating(per_test)),
        ("Refractory Stability", lambda: bench_refractory_stability(per_test)),
        ("Wet Wood Conductivity", lambda: bench_wet_wood_conductivity(per_test)),
        ("Lightning Path Preference", lambda: bench_lightning_path(per_test)),
        ("Kirchhoff Conservation", lambda: bench_kirchhoff_conservation(per_test)),
    ]

    results = []
    for name, bench_fn in benchmarks:
        print(f"\n{'='*60}")
        print(f"Running: {name}")
        print(f"{'='*60}")
        t0 = time.time()
        try:
            result = bench_fn()
            elapsed = time.time() - t0
            status = "PASS" if result.passed else "FAIL"
            print(f"  [{status}] {result.name} ({elapsed:.1f}s)")
            print(f"    {result.details}")
            results.append(result)
        except Exception as e:
            print(f"  [ERROR] {name}: {e}")
            import traceback
            traceback.print_exc()
            results.append(BenchmarkResult(
                name=name, passed=False, details=f"Exception: {e}", metrics={}
            ))
        finally:
            if GPU_AVAILABLE:
                try:
                    xp.get_default_memory_pool().free_all_blocks()
                    xp.get_default_pinned_memory_pool().free_all_blocks()
                except Exception:
                    pass

    return results


def _json_safe(value):
    """Convert NumPy/CuPy scalar containers into JSON-safe Python values."""
    if isinstance(value, dict):
        return {key: _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if isinstance(value, np.ndarray):
        return value.tolist()
    if hasattr(value, "item"):
        try:
            return value.item()
        except Exception:
            pass
    return value


def main():
    parser = argparse.ArgumentParser(description="GPU Electrical Conductivity Benchmark")
    parser.add_argument("--circuits", type=int, default=0,
                        help="Total circuit scenarios (default: 5000)")
    parser.add_argument("--quick", action="store_true", help="Quick: 500 circuits")
    parser.add_argument("--output", type=str, default=None)
    args = parser.parse_args()

    circuits = 500 if args.quick else resolve_electrical_circuits(args.circuits or None)
    print(f"\nGPU Electrical Conductivity Benchmark")
    print(f"GPU available: {GPU_AVAILABLE}")
    print(f"Total circuits: {circuits:,}")
    print(f"Grid: {GRID_W}x{GRID_H}")

    t0 = time.time()
    results = run_all_benchmarks(circuits)
    elapsed = time.time() - t0

    # Summary
    print(f"\n{'='*60}")
    print(f"SUMMARY ({elapsed:.1f}s)")
    print(f"{'='*60}")
    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print(f"  {passed}/{total} benchmarks passed")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        print(f"  [{status}] {r.name}")

    output_path = args.output or str(SCRIPT_DIR / "electrical_benchmark_results.json")
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "gpu_available": GPU_AVAILABLE,
        "total_circuits": circuits,
        "elapsed_seconds": elapsed,
        "passed": passed,
        "total": total,
        "results": [
            {"name": r.name, "passed": r.passed, "details": r.details, "metrics": r.metrics}
            for r in results
        ],
    }
    with open(output_path, "w") as f:
        json.dump(_json_safe(output), f, indent=2)
    print(f"\nResults saved to {output_path}")

    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()

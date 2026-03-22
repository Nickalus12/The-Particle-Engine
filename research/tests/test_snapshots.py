import json
import pytest


class TestOracleSnapshots:
    """Snapshot tests for physics oracle (ground_truth.json) stability."""

    # --- Element count & names ---

    def test_element_count_stable(self, snapshot, ground_truth):
        """Number of elements in oracle should be stable."""
        gravity = ground_truth.get("gravity_all", {})
        assert len(gravity) == snapshot

    def test_element_names_stable(self, snapshot, ground_truth):
        """Element names in the oracle should not change."""
        gravity = ground_truth.get("gravity_all", {})
        assert sorted(gravity.keys()) == snapshot

    # --- Gravity ---

    def test_gravity_oracle_stable(self, snapshot, ground_truth):
        """Gravity oracle data structure should not change unexpectedly."""
        gravity_data = ground_truth.get("gravity_all", {})
        structure = {k: list(v.keys()) for k, v in gravity_data.items()}
        assert structure == snapshot

    def test_gravity_values_stable(self, snapshot, ground_truth):
        """Per-element gravity strength values."""
        gravity_data = ground_truth.get("gravity_all", {})
        values = {k: v.get("gravity") for k, v in gravity_data.items()}
        assert values == snapshot

    def test_gravity_directions_stable(self, snapshot, ground_truth):
        """Per-element gravity directions (up/down/none)."""
        gravity_data = ground_truth.get("gravity_all", {})
        directions = {k: v.get("direction") for k, v in gravity_data.items()}
        assert directions == snapshot

    def test_gravity_max_velocities_stable(self, snapshot, ground_truth):
        """Per-element max velocity values."""
        gravity_data = ground_truth.get("gravity_all", {})
        max_vels = {k: v.get("maxVelocity") for k, v in gravity_data.items()}
        assert max_vels == snapshot

    def test_gravity_final_positions_stable(self, snapshot, ground_truth):
        """Per-element final positions after 60 frames."""
        gravity_data = ground_truth.get("gravity_all", {})
        finals = {k: v.get("final_position") for k, v in gravity_data.items()}
        assert finals == snapshot

    # --- Density ---

    def test_density_ordering_stable(self, snapshot, ground_truth):
        """Density ordering should be stable across oracle regenerations."""
        ordering = ground_truth.get("density_ordering", {})
        our_order = ordering.get("our_order", [])
        assert our_order == snapshot

    def test_density_values_stable(self, snapshot, ground_truth):
        """Our 0-255 density values for all elements."""
        ordering = ground_truth.get("density_ordering", {})
        densities = ordering.get("our_densities_0_255", {})
        assert densities == snapshot

    def test_density_accuracy_stable(self, snapshot, ground_truth):
        """Ordering accuracy vs real physics should remain stable."""
        ordering = ground_truth.get("density_ordering", {})
        accuracy = ordering.get("ordering_accuracy")
        assert accuracy == snapshot

    # --- Phase changes ---

    def test_phase_change_products_stable(self, snapshot, ground_truth):
        """Phase change products should not change."""
        phases = ground_truth.get("phase_changes_all", {})
        products = {}
        for element, transitions in phases.items():
            for transition_type, data in transitions.items():
                key = f"{element}_{transition_type}"
                products[key] = data.get("becomes", "")
        assert products == snapshot

    def test_phase_change_thresholds_stable(self, snapshot, ground_truth):
        """Phase change temperature thresholds."""
        phases = ground_truth.get("phase_changes_all", {})
        thresholds = {}
        for element, transitions in phases.items():
            for transition_type, data in transitions.items():
                key = f"{element}_{transition_type}"
                thresholds[key] = data.get("threshold")
        assert thresholds == snapshot

    def test_phase_change_triggers_stable(self, snapshot, ground_truth):
        """Phase change trigger types (above/below)."""
        phases = ground_truth.get("phase_changes_all", {})
        triggers = {}
        for element, transitions in phases.items():
            for transition_type, data in transitions.items():
                key = f"{element}_{transition_type}"
                triggers[key] = data.get("trigger")
        assert triggers == snapshot

    def test_phase_change_count_stable(self, snapshot, ground_truth):
        """Total number of phase change rules."""
        phases = ground_truth.get("phase_changes", {})
        assert len(phases) == snapshot

    # --- Reactions ---

    def test_reaction_products_stable(self, snapshot, ground_truth):
        """Reaction products should not drift."""
        reactions = ground_truth.get("reactions_all", {})
        products = {}
        for name, data in reactions.items():
            products[name] = {
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
        assert products == snapshot

    def test_reaction_count_stable(self, snapshot, ground_truth):
        """Total number of registered reactions."""
        reactions = ground_truth.get("reactions_all", {})
        assert len(reactions) == snapshot

    def test_reaction_probabilities_stable(self, snapshot, ground_truth):
        """Probability values for all reactions."""
        reactions = ground_truth.get("reactions_all", {})
        probs = {name: data.get("probability") for name, data in reactions.items()}
        assert probs == snapshot

    def test_reaction_determinism_flags_stable(self, snapshot, ground_truth):
        """Which reactions are deterministic vs probabilistic."""
        reactions = ground_truth.get("reactions_all", {})
        flags = {
            name: data.get("is_deterministic") for name, data in reactions.items()
        }
        assert flags == snapshot

    def test_fire_reactions_stable(self, snapshot, ground_truth):
        """All fire-source reactions and their products."""
        reactions = ground_truth.get("reactions_all", {})
        fire = {
            name: {
                "target": data.get("target"),
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
            for name, data in reactions.items()
            if data.get("source") == "fire"
        }
        assert fire == snapshot

    def test_water_reactions_stable(self, snapshot, ground_truth):
        """All water-source reactions."""
        reactions = ground_truth.get("reactions_all", {})
        water = {
            name: {
                "target": data.get("target"),
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
            for name, data in reactions.items()
            if data.get("source") == "water"
        }
        assert water == snapshot

    def test_acid_reactions_stable(self, snapshot, ground_truth):
        """All acid-source reactions."""
        reactions = ground_truth.get("reactions_all", {})
        acid = {
            name: {
                "target": data.get("target"),
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
            for name, data in reactions.items()
            if data.get("source") == "acid"
        }
        assert acid == snapshot

    def test_lava_reactions_stable(self, snapshot, ground_truth):
        """All lava-source reactions."""
        reactions = ground_truth.get("reactions_all", {})
        lava = {
            name: {
                "target": data.get("target"),
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
            for name, data in reactions.items()
            if data.get("source") == "lava"
        }
        assert lava == snapshot

    def test_lightning_reactions_stable(self, snapshot, ground_truth):
        """All lightning-source reactions."""
        reactions = ground_truth.get("reactions_all", {})
        lightning = {
            name: {
                "target": data.get("target"),
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
            for name, data in reactions.items()
            if data.get("source") == "lightning"
        }
        assert lightning == snapshot

    # --- Torricelli ---

    def test_torricelli_velocities_stable(self, snapshot, ground_truth):
        """Torricelli outflow expected velocities."""
        torr = ground_truth.get("torricelli", {})
        assert torr.get("expected_velocity_cells_per_frame") == snapshot

    def test_torricelli_heights_stable(self, snapshot, ground_truth):
        """Torricelli height test points."""
        torr = ground_truth.get("torricelli", {})
        assert torr.get("heights_cells") == snapshot

    # --- Beverloo ---

    def test_beverloo_flow_rates_stable(self, snapshot, ground_truth):
        """Hourglass flow rate expectations."""
        bev = ground_truth.get("beverloo", {})
        assert bev.get("expected_relative_flow") == snapshot

    def test_beverloo_openings_stable(self, snapshot, ground_truth):
        """Beverloo opening sizes tested."""
        bev = ground_truth.get("beverloo", {})
        assert bev.get("openings_cells") == snapshot

    # --- Buoyancy ---

    def test_buoyancy_predictions_stable(self, snapshot, ground_truth):
        """Sink/float predictions for all elements."""
        buoy = ground_truth.get("buoyancy", {})
        predictions = {
            el: {"sink": data.get("should_sink"), "float": data.get("should_float")}
            for el, data in buoy.items()
        }
        assert predictions == snapshot

    # --- Viscosity ---

    def test_viscosity_ordering_stable(self, snapshot, ground_truth):
        """Liquid viscosity ranking."""
        visc = ground_truth.get("viscosity", {})
        assert visc.get("expected_spread_ordering") == snapshot

    def test_viscosity_values_stable(self, snapshot, ground_truth):
        """Our viscosity values (1-10 scale)."""
        visc = ground_truth.get("viscosity", {})
        assert visc.get("our_viscosity_1_10") == snapshot

    # --- Thermal conductivity ---

    def test_conduction_ordering_stable(self, snapshot, ground_truth):
        """Thermal conductivity ranking (our values)."""
        cond = ground_truth.get("thermal_conductivity", {})
        assert cond.get("our_ordering") == snapshot

    def test_conduction_values_stable(self, snapshot, ground_truth):
        """Our thermal conductivity values (0-1 scale)."""
        cond = ground_truth.get("thermal_conductivity", {})
        assert cond.get("our_0_to_1") == snapshot

    # --- Angle of repose ---

    def test_angle_of_repose_values_stable(self, snapshot, ground_truth):
        """Expected angle of repose per granular element."""
        aor = ground_truth.get("angle_of_repose", {})
        values = {}
        for el, data in aor.items():
            if isinstance(data, dict):
                values[el] = {
                    "min": data.get("min"),
                    "max": data.get("max"),
                    "typical": data.get("typical"),
                }
        assert values == snapshot

    # --- Cooling curves ---

    def test_cooling_half_lives_stable(self, snapshot, ground_truth):
        """Newton cooling half-life values per element."""
        cooling = ground_truth.get("cooling_all", {})
        half_lives = {
            el: data.get("half_life_frames") for el, data in cooling.items()
        }
        assert half_lives == snapshot

    def test_cooling_k_values_stable(self, snapshot, ground_truth):
        """Newton cooling rate constants per element."""
        cooling = ground_truth.get("cooling_all", {})
        k_values = {el: data.get("k") for el, data in cooling.items()}
        assert k_values == snapshot

    # --- Explosion falloff ---

    def test_explosion_energy_ratios_stable(self, snapshot, ground_truth):
        """Explosion energy falloff curve."""
        expl = ground_truth.get("explosion_falloff", {})
        assert expl.get("expected_energy_ratio") == snapshot

    # --- Fire triangle ---

    def test_flammable_materials_stable(self, snapshot, ground_truth):
        """List of flammable materials."""
        ft = ground_truth.get("fire_triangle", {})
        assert sorted(ft.get("flammable_materials", [])) == snapshot

    def test_non_flammable_materials_stable(self, snapshot, ground_truth):
        """List of non-flammable materials."""
        ft = ground_truth.get("fire_triangle", {})
        assert sorted(ft.get("non_flammable", [])) == snapshot

    # --- Conservation laws ---

    def test_conservation_mass_tolerance_stable(self, snapshot, ground_truth):
        """Mass conservation tolerance."""
        cm = ground_truth.get("conservation_mass", {})
        assert cm.get("tolerance_percent") == snapshot

    def test_conservation_energy_tolerance_stable(self, snapshot, ground_truth):
        """Energy conservation tolerance."""
        ce = ground_truth.get("conservation_energy", {})
        assert ce.get("tolerance_percent") == snapshot

    # --- Gravity trajectory reference ---

    def test_gravity_trajectory_frames_stable(self, snapshot, ground_truth):
        """Reference gravity trajectory frame count."""
        gt = ground_truth.get("gravity_trajectory", {})
        assert gt.get("frames") == snapshot

    def test_gravity_trajectory_real_physics_stable(self, snapshot, ground_truth):
        """Reference real-physics trajectory values."""
        gt = ground_truth.get("gravity_trajectory", {})
        assert gt.get("real_physics_cells") == snapshot

    # --- Pressure depth ---

    def test_pressure_depth_linearity_stable(self, snapshot, ground_truth):
        """Pressure-depth linearity R-squared value."""
        pd = ground_truth.get("pressure_depth", {})
        assert pd.get("linearity_r_squared") == snapshot

    # --- Heat conduction chain ---

    def test_heat_conduction_steady_state_stable(self, snapshot, ground_truth):
        """Steady-state temperature profile for conduction chain."""
        hc = ground_truth.get("heat_conduction", {})
        assert hc.get("steady_state_temps") == snapshot

    # --- Connected vessels ---

    def test_connected_vessels_tolerance_stable(self, snapshot, ground_truth):
        """Connected vessels level tolerance."""
        cv = ground_truth.get("connected_vessels", {})
        assert cv.get("tolerance_cells") == snapshot

    # --- U-tube fluids ---

    def test_u_tube_ratio_stable(self, snapshot, ground_truth):
        """U-tube expected oil/water height ratio."""
        ut = ground_truth.get("u_tube_fluids", {})
        assert ut.get("our_expected_ratio") == snapshot


class TestVisualOracleSnapshots:
    """Snapshot tests for visual oracle (visual_ground_truth.json) stability."""

    def test_element_lab_colors_stable(self, snapshot, visual_truth):
        """LAB color values for all elements."""
        assert visual_truth.get("element_lab_colors") == snapshot

    def test_delta_e_threshold_stable(self, snapshot, visual_truth):
        """Minimum Delta E threshold."""
        assert visual_truth.get("min_delta_e_threshold") == snapshot

    def test_delta_e_pairs_stable(self, snapshot, visual_truth):
        """All Delta E pair distances."""
        assert visual_truth.get("delta_e_pairs") == snapshot

    def test_texture_entropy_ranges_stable(self, snapshot, visual_truth):
        """Expected entropy ranges per element."""
        assert visual_truth.get("texture_entropy") == snapshot

    def test_transparency_ranges_stable(self, snapshot, visual_truth):
        """Alpha ranges for transparent elements."""
        assert visual_truth.get("transparency") == snapshot

    def test_sky_gradient_params_stable(self, snapshot, visual_truth):
        """Sky gradient lightness ranges."""
        assert visual_truth.get("sky_gradient") == snapshot

    def test_underground_thresholds_stable(self, snapshot, visual_truth):
        """Underground brightness limits."""
        assert visual_truth.get("underground") == snapshot

    def test_glow_params_stable(self, snapshot, visual_truth):
        """Glow falloff type and max radius."""
        assert visual_truth.get("glow") == snapshot

    def test_water_depth_params_stable(self, snapshot, visual_truth):
        """Water depth gradient parameters."""
        assert visual_truth.get("water_depth") == snapshot

    def test_contrast_pairs_stable(self, snapshot, visual_truth):
        """Critical contrast pairs and minimum ratio."""
        assert visual_truth.get("contrast") == snapshot

    def test_known_similar_pairs_stable(self, snapshot, visual_truth):
        """Known similar element pairs."""
        assert visual_truth.get("known_similar_pairs") == snapshot

    def test_light_emission_params_stable(self, snapshot, visual_truth):
        """Light emission intensity and colors."""
        assert visual_truth.get("light_emission") == snapshot

    def test_base_alphas_stable(self, snapshot, visual_truth):
        """Base alpha values for all elements."""
        assert visual_truth.get("base_alphas") == snapshot

    def test_base_rgb_stable(self, snapshot, visual_truth):
        """Base RGB values for all elements."""
        assert visual_truth.get("base_rgb") == snapshot

    def test_texture_detail_stable(self, snapshot, visual_truth):
        """Texture detail thresholds."""
        assert visual_truth.get("texture_detail") == snapshot

    def test_micro_particles_stable(self, snapshot, visual_truth):
        """Micro particle brightness thresholds."""
        assert visual_truth.get("micro_particles") == snapshot

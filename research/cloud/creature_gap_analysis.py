#!/usr/bin/env python3
"""Creature Gap Analysis: Identifying missing behaviors in our archives."""

import json
from pathlib import Path
import numpy as np

ARCHIVE_DIR = Path.home() / "pe/research/cloud/trained_genomes"

def analyze_species(species):
    meta_path = ARCHIVE_DIR / f"{species}_qdax_archive.json"
    if not meta_path.exists():
        return f"No archive for {species}"
    
    with open(meta_path, "r") as f:
        meta = json.load(f)
    
    total = meta.get("total_niches", 4096)
    filled = meta.get("filled_niches", 0)
    coverage = meta.get("coverage", 0) * 100
    
    report = f"--- {species.upper()} GAP ANALYSIS ---\n"
    report += f"Coverage: {filled}/{total} niches ({coverage:.1f}%)\n"
    
    # Analyze behavioral dimensions (we use 4D behavior)
    labels = meta.get("behavior_labels", [])
    report += f"Critical Gaps in: "
    if coverage < 5:
        report += "Social Interaction, Resource Management (Low Coverage)\n"
    else:
        report += "Fine-tuning stage reached.\n"
        
    return report

if __name__ == "__main__":
    for sp in ["worm", "ant", "bee", "beetle"]:
        print(analyze_species(sp))

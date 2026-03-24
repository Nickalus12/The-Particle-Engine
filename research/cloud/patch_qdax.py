import sys
from pathlib import Path

file_path = Path.home() / "pe/research/cloud/qdax_creature_trainer.py"
content = file_path.read_text()

# 1. Add --batch to parser
if 'parser.add_argument("--batch"' not in content:
    content = content.replace(
        'parser.add_argument("--grid"',
        'parser.add_argument("--batch", type=int, default=None, help="Batch/population size")\n    parser.add_argument("--grid"'
    )

# 2. Use args.batch in train_qdax or in main()
# Looking at the code, pop_size is set in train_qdax
# I'll pass it into train_qdax from main()

if 'train_qdax(sp, args.iterations, grid_shape, args.seed, args.curriculum)' in content:
    content = content.replace(
        'train_qdax(sp, args.iterations, grid_shape, args.seed, args.curriculum)',
        'train_qdax(sp, args.iterations, grid_shape, args.seed, args.curriculum, args.batch)'
    )

if 'def train_qdax(species_name, iterations=500, grid_shape=None, seed=42, use_curriculum=False):' in content:
    content = content.replace(
        'def train_qdax(species_name, iterations=500, grid_shape=None, seed=42, use_curriculum=False):',
        'def train_qdax(species_name, iterations=500, grid_shape=None, seed=42, use_curriculum=False, batch_size=None):'
    )

if 'pop_size = cfg["pop_size"]' in content:
    content = content.replace(
        'pop_size = cfg["pop_size"]',
        'pop_size = batch_size if batch_size else cfg["pop_size"]'
    )

file_path.write_text(content)
print("Successfully patched qdax_creature_trainer.py")

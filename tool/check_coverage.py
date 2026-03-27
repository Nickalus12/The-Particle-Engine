#!/usr/bin/env python3
import argparse
import pathlib
import sys


def parse_lcov(path: pathlib.Path) -> tuple[int, int]:
    lines_found = 0
    lines_hit = 0

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("LF:"):
            lines_found += int(raw[3:])
        elif raw.startswith("LH:"):
            lines_hit += int(raw[3:])

    return lines_hit, lines_found


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate aggregate line coverage from lcov.info."
    )
    parser.add_argument("lcov_file", type=pathlib.Path, help="Path to lcov.info")
    parser.add_argument(
        "--min",
        dest="min_coverage",
        type=float,
        default=45.0,
        help="Minimum required line coverage percentage.",
    )
    args = parser.parse_args()

    if not args.lcov_file.exists():
        print(f"ERROR: Coverage file not found: {args.lcov_file}")
        return 2

    hit, found = parse_lcov(args.lcov_file)
    if found <= 0:
        print("ERROR: Coverage file has no LF entries.")
        return 2

    pct = (hit / found) * 100.0
    print(f"Line coverage: {pct:.2f}% ({hit}/{found})")
    print(f"Minimum required: {args.min_coverage:.2f}%")

    summary_path = pathlib.Path(".coverage-summary.txt")
    summary_path.write_text(
        (
            "## Flutter Coverage\n"
            f"- Line coverage: **{pct:.2f}%** ({hit}/{found})\n"
            f"- Minimum required: **{args.min_coverage:.2f}%**\n"
        ),
        encoding="utf-8",
    )

    if pct < args.min_coverage:
        print("ERROR: Coverage is below minimum threshold.")
        return 1

    print("Coverage gate passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

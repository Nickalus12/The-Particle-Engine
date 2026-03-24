import re
import sys

def optimize_loops(content):
    # Pattern 1: [1, -1] or [-1, 1]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*1\s*,\s*-1\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? 1 : -1;',
        content
    )
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*-1\s*,\s*1\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? -1 : 1;',
        content
    )
    # Pattern 2: [dir, -dir]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*dir\s*,\s*-dir\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? dir : -dir;',
        content
    )
    # Pattern 3: [0, 1]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*0\s*,\s*1\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? 0 : 1;',
        content
    )
    # Pattern 4: [dir1, dir2]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*dir1\s*,\s*dir2\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? dir1 : dir2;',
        content
    )
    # Pattern 5: wrapX
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*wrapX\(([^)]+)\)\s*,\s*wrapX\(([^)]+)\)\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? wrapX(\3) : wrapX(\4);',
        content
    )
    # Pattern 6: sy in [y, y - gravityDir]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*y\s*,\s*y\s*-\s*gravityDir\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 2; \2_i++) { final \2 = \2_i == 0 ? y : y - gravityDir;',
        content
    )
    # Pattern 7: [-1, 0, 1]
    content = re.sub(
        r'for \(\s*(var|final|int)\s+(\w+)\s+in\s+\[\s*-1\s*,\s*0\s*,\s*1\s*\]\s*\)\s*\{',
        r'for (int \2_i = 0; \2_i < 3; \2_i++) { final \2 = \2_i - 1;',
        content
    )
    return content

if __name__ == "__main__":
    with open("lib/simulation/element_behaviors.dart", "r", encoding="utf-8") as f:
        content = f.read()
    content = optimize_loops(content)
    with open("lib/simulation/element_behaviors.dart", "w", encoding="utf-8") as f:
        f.write(content)

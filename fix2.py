import os

path = r"lib/simulation/simulation_engine.dart"
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

idx1 = text.find("  };\n}")
if idx1 != -1:
    idx2 = text.find("  };\n}", idx1 + 1)
    if idx2 != -1:
        text = text[:idx1 + 6]
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
            print("Fixed duplicate")

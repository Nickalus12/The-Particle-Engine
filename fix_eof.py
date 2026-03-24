import os

path = r"lib/simulation/simulation_engine.dart"
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

idx = text.rfind("  };\n}")
if idx != -1:
    text = text[:idx + 6]
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
        print("Fixed EOF")

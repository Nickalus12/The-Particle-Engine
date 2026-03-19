#!/usr/bin/env python3
"""Start the MLflow dashboard with all data loaded."""
from __future__ import annotations

import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

RESEARCH_DIR = Path(__file__).resolve().parent


def main():
    # Import latest data
    print("Importing latest experiment data...")
    subprocess.run(
        [sys.executable, str(RESEARCH_DIR / "import_history.py")], check=True
    )

    # Start MLflow server
    db_uri = f"sqlite:///{RESEARCH_DIR / 'mlflow.db'}"
    port = 8080

    print(f"\nStarting MLflow dashboard at http://localhost:{port}")
    print("Press Ctrl+C to stop\n")

    def open_browser():
        time.sleep(2)
        webbrowser.open(f"http://localhost:{port}")

    threading.Thread(target=open_browser, daemon=True).start()

    subprocess.run(
        [
            sys.executable,
            "-m",
            "mlflow",
            "server",
            "--port",
            str(port),
            "--backend-store-uri",
            db_uri,
            "--host",
            "127.0.0.1",
        ]
    )


if __name__ == "__main__":
    main()

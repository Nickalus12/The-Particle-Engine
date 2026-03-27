"""Verify local LGTM/Grafana provisioning and basic query health."""
from __future__ import annotations

import argparse
import base64
import json
import urllib.error
import urllib.parse
import urllib.request


def _get_json(url: str, headers: dict[str, str] | None = None) -> object:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=6) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _basic_auth(user: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    return {"Authorization": f"Basic {token}"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify local observability stack health.")
    parser.add_argument("--grafana-url", default="http://localhost:3000")
    parser.add_argument("--prom-url", default="http://localhost:9090")
    parser.add_argument("--dashboard-uid", default="particle-perf-overview")
    parser.add_argument("--alert-uid", default="pe-timeout-targets")
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password", default="admin")
    args = parser.parse_args()

    headers = _basic_auth(args.user, args.password)

    try:
        health = _get_json(f"{args.grafana_url}/api/health", headers=headers)
        if not isinstance(health, dict) or health.get("database") != "ok":
            raise RuntimeError("Grafana health check did not report database=ok")

        dash = _get_json(
            f"{args.grafana_url}/api/dashboards/uid/{args.dashboard_uid}",
            headers=headers,
        )
        if not isinstance(dash, dict) or dash.get("dashboard", {}).get("uid") != args.dashboard_uid:
            raise RuntimeError("Dashboard UID not found in Grafana API response")

        rules = _get_json(f"{args.grafana_url}/api/v1/provisioning/alert-rules", headers=headers)
        if not isinstance(rules, list):
            raise RuntimeError("Alert rules response was not a list")
        if args.alert_uid not in {str(r.get("uid", "")) for r in rules if isinstance(r, dict)}:
            raise RuntimeError(f"Alert UID not found: {args.alert_uid}")

        q = urllib.parse.quote("sum(particle_engine_tests_total)")
        prom = _get_json(f"{args.prom_url}/api/v1/query?query={q}")
        if not isinstance(prom, dict) or prom.get("status") != "success":
            raise RuntimeError("Prometheus query endpoint did not return success")
    except (urllib.error.URLError, RuntimeError, ValueError) as err:
        print(f"observability_verify=failed reason={err}")
        return 1

    print("observability_verify=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

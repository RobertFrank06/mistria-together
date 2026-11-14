#!/usr/bin/env python3
"""Automated game test suite. See IMPLEMENT.md, Phase 0.

  tools/gametest.py list
  tools/gametest.py run [name ...] [--keep] [--players N] [--timeout S]
"""
import argparse
import importlib
import pkgutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gametest as gt  # noqa: E402
import gametest.scenarios as scen_pkg  # noqa: E402


def load_all():
    out = {}
    for m in pkgutil.iter_modules(scen_pkg.__path__):
        if m.name.startswith("_"):
            continue
        mod = importlib.import_module(f"gametest.scenarios.{m.name}")
        out[getattr(mod, "NAME", m.name)] = mod
    return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="what", required=True)
    sub.add_parser("list")
    r = sub.add_parser("run")
    r.add_argument("names", nargs="*")
    r.add_argument("--keep", action="store_true", help="leave instances running afterwards")
    r.add_argument("--players", type=int, default=0)
    r.add_argument("--timeout", type=int, default=90)
    r.add_argument("--no-install", action="store_true")
    a = ap.parse_args()

    scenarios = load_all()
    if a.what == "list":
        for name in sorted(scenarios):
            print(name)
        return 0

    names = a.names or sorted(n for n, m in scenarios.items() if not getattr(m, 'MANUAL', False))
    missing = [n for n in names if n not in scenarios]
    if missing:
        print(f"unknown scenario(s): {missing}")
        return 2
    gt.RIG.mkdir(parents=True, exist_ok=True)
    if not a.no_install:
        print("installing mod into the rig ...")
        r = subprocess.run([str(gt.RIG_SH), "install"], env=dict(__import__("os").environ, MT_RIG=str(gt.RIG)), capture_output=True, text=True, timeout=900)
        if r.returncode != 0:
            print(r.stdout[-2000:], r.stderr[-2000:])
            return 2
    results = {}
    try:
        for n in names:
            results[n] = gt.run_scenario(scenarios[n], a.players, a.keep, a.timeout)
    finally:
        if not a.keep:
            pass  # run_scenario already stopped its own process groups
    failed = [n for n, ok in results.items() if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} scenarios passed;"
          f" {gt._report['passed']} assertions ok, {gt._report['failed']} failed")
    for n in failed:
        print(f"  FAILED {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

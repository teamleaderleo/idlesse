#!/usr/bin/env python3
"""Bounded synthetic benchmark; fixtures are deleted even if a child fails."""
import json
import pathlib
import subprocess
import tempfile
import time
import sys

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / "build/Idlesse.app/Contents/MacOS/Idlesse"
output = root / "build/benchmarks"
output.mkdir(parents=True, exist_ok=True)
# Keep a stable runner if a development build happens while measurements run.
runner_app = output / "Benchmark.app"
runner = runner_app / "Contents/MacOS/Idlesse"
import shutil
shutil.copytree(binary.parents[2], runner_app, dirs_exist_ok=True)
results = []
try:
    with tempfile.TemporaryDirectory(prefix="fixtures-", dir=output) as fixtures:
        subprocess.run([str(runner), "--benchmark", "fixture", fixtures], check=True, timeout=120)
        for mode in (sys.argv[1:] or ["bounded", "full-resolution", "lifecycle"]):
            print(f"Measuring {mode}", flush=True)
            with (output / f"{mode}.json").open("w") as stdout, (output / f"{mode}.log").open("w") as stderr:
                subprocess.run(["/usr/bin/time", "-l", str(runner), "--benchmark", mode, fixtures],
                               stdout=stdout, stderr=stderr, check=True, timeout=120)
            result = json.loads((output / f"{mode}.json").read_text())
            results.append(result)
            print(f"{mode}: {result['peakSampledFootprint']/1048576:.1f} MiB peak sampled footprint", flush=True)
    (output / "results.json").write_text(json.dumps({"measuredAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "results": results}, indent=2))
finally:
    shutil.rmtree(runner_app)

#!/usr/bin/env python3
"""Offline payload/copy benchmark; never launches an agent or reads user sessions."""
import argparse, hashlib, importlib.util, json, os, pathlib, statistics, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as folder:
    os.environ["AWB_NATIVE_ROOT"] = folder
    spec = importlib.util.spec_from_file_location("bridge", root / "remote/native-agent-service.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    results = []
    for count in [200, 2000, 10000]:
        messages = []
        for index in range(count):
            for role, prefix in [("user", "u"), ("assistant", "a")]:
                messages.append(bridge.normalize({"role": role, "content": "中文 English fixture " * 16}, prefix + str(index)))
        session = bridge.Session(dict(id="fixture", provider="omp", title="Fixture", cwd="/fixture", model="m",
            busy=True, archived=False, updated=0, revision=1, completed=0, messages=messages, interactions=[], error=None))
        session.persist = lambda: None
        first = session.snapshot(turns="50")
        session.upsert({"role": "assistant", "content": "流式正文 updated"}, "a" + str(count - 1))
        session.touch()
        def measure(**query):
            timings = []
            for _ in range(7):
                start = time.perf_counter()
                wire = json.dumps(session.snapshot(**query), ensure_ascii=False).encode()
                timings.append((time.perf_counter() - start) * 1000)
            return {"bytes": len(wire), "copy_and_json_ms": timings, "median_ms": statistics.median(timings)}
        results.append({"turns": count, "full": measure(), "initial_50_turns": measure(turns="50"),
            "delta": measure(revision="1", start=str(first["history"]["start"]), epoch=first["history"]["epoch"])})
        if count == 200:
            session.upsert({"role":"assistant", "content":"older same-ID edit"}, "a110");session.touch()
            page = session.snapshot(before=str(first["history"]["start"]), epoch=first["history"]["epoch"], turns="50")
            delta = session.snapshot(revision=str(first["revision"]), start=str(page["history"]["start"]), epoch=first["history"]["epoch"])
            expected = session.snapshot()["messages"][page["history"]["start"]:]
            (args.output / "wire.json").write_text(json.dumps({"first":first,"page":page,"delta":delta,"expected":expected},ensure_ascii=False))
    report = {"boundary":"In-process synthetic bridge snapshot copy plus JSON encoding, not SSH latency or UI FPS",
        "service_sha256":hashlib.sha256((root/"remote/native-agent-service.py").read_bytes()).hexdigest(), "results":results}
    (args.output / "bridge.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(results, indent=2))

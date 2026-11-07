"""Submits train_and_promote.yaml as a logged-in user and waits for the run.

The user's oauth2-proxy session cookie (from the Dex login) is what the KFP
API sees; KFP authorizes the request against the target namespace with a
SubjectAccessReview, the same check the UI goes through.

Usage:
  python submit.py --host http://127.0.0.1:18080/pipeline --cookie-jar alice.jar \
      --namespace team-a --param version=v1 --param label_noise=0.0
Prints one JSON line: run_id, state, and the state of each task.
"""
import argparse
import http.cookiejar
import json
import pathlib
import sys
import time

import kfp

PIPELINE = pathlib.Path(__file__).with_name("train_and_promote.yaml")


def session_cookie(jar_path: str) -> str:
    jar = http.cookiejar.MozillaCookieJar(jar_path)
    jar.load(ignore_discard=True, ignore_expires=True)
    return "; ".join(f"{c.name}={c.value}" for c in jar if c.name.startswith("oauth2_proxy"))


def parse_value(raw: str):
    for cast in (int, float):
        try:
            return cast(raw)
        except ValueError:
            pass
    return raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--cookie-jar", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--param", action="append", default=[])
    ap.add_argument("--run-name", default="train-and-promote")
    ap.add_argument("--timeout", type=int, default=1200)
    args = ap.parse_args()

    params = {}
    for item in args.param:
        key, _, value = item.partition("=")
        params[key] = parse_value(value)
    params.setdefault("namespace", args.namespace)

    client = kfp.Client(host=args.host, cookies=session_cookie(args.cookie_jar),
                        namespace=args.namespace)
    result = client.create_run_from_pipeline_package(
        str(PIPELINE), arguments=params, run_name=args.run_name,
        experiment_name=f"{args.namespace}-promotions", namespace=args.namespace,
        enable_caching=False)

    deadline = time.time() + args.timeout
    state = None
    while time.time() < deadline:
        run = client.get_run(result.run_id)
        state = run.state
        if state in ("SUCCEEDED", "FAILED", "CANCELED", "SKIPPED"):
            break
        time.sleep(10)

    run = client.get_run(result.run_id)
    tasks = {}
    details = getattr(run, "run_details", None)
    for task in (getattr(details, "task_details", None) or []):
        name = task.display_name or ""
        if name and not name.startswith(("root", "executor")):
            tasks[name] = task.state
    print(json.dumps({"run_id": result.run_id, "state": run.state, "tasks": tasks}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Render the Helm chart and validate every collector ConfigMap with the real otelcol binary.

usage: helm template ... | python3 scripts/validate_collector.py [--image IMAGE]

Each component's ConfigMap is validated with the env vars its workload sets.
fieldRef/secret-backed vars get placeholder values. Requires docker.
"""
import argparse
import os
import subprocess
import sys
import tempfile

import yaml

PLACEHOLDERS = {
    "POD_NAME": "pod-0",
    "POD_NAMESPACE": "monitoring",
    "POD_IP": "127.0.0.1",
    "K8S_NODE_NAME": "node-0",
    "K8S_NODE_IP": "127.0.0.1",
    "RABBITMQ_PASSWORD": "placeholder",
    # sigv4auth resolves credentials at start-up; validation only needs them to exist
    "AWS_ACCESS_KEY_ID": "AKIAPLACEHOLDER",
    "AWS_SECRET_ACCESS_KEY": "placeholder",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=None)
    args = ap.parse_args()

    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    configs = {d["metadata"]["name"]: d["data"]["config.yaml"] for d in docs if d["kind"] == "ConfigMap"}
    workloads = [d for d in docs if d["kind"] in ("Deployment", "DaemonSet")]
    if not workloads:
        sys.exit("no collector workloads rendered")

    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        os.chmod(tmp, 0o755)  # collector image runs as non-root
        sa = os.path.join(tmp, "sa")
        os.makedirs(sa)
        for f in ("token", "ca.crt", "namespace"):
            open(os.path.join(sa, f), "w").write("placeholder")
            os.chmod(os.path.join(sa, f), 0o644)
        os.chmod(sa, 0o755)
        for w in workloads:
            name = w["metadata"]["name"]
            container = w["spec"]["template"]["spec"]["containers"][0]
            image = args.image or container["image"]
            env = dict(PLACEHOLDERS)
            for e in container.get("env", []):
                if "value" in e:
                    env[e["name"]] = str(e["value"])
            cfg_path = os.path.join(tmp, f"{name}.yaml")
            env_path = os.path.join(tmp, f"{name}.env")
            open(cfg_path, "w").write(configs[name])
            open(env_path, "w").write("".join(f"{k}={v}\n" for k, v in env.items()))
            os.chmod(cfg_path, 0o644)
            cmd = [
                "docker", "run", "--rm", "--env-file", env_path,
                "-v", f"{tmp}:/cfg:ro",
                "-v", f"{sa}:/var/run/secrets/kubernetes.io/serviceaccount:ro",
                image, "validate", f"--config=/cfg/{name}.yaml",
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            out = "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "IMDS" not in l)
            deprecated = [l for l in out.splitlines() if "deprecated" in l]
            if r.returncode != 0:
                failed = True
                print(f"FAIL {name}\n{out}")
            else:
                print(f"OK   {name}" + (f" ({len(deprecated)} deprecation warnings)" if deprecated else ""))
                for l in deprecated:
                    print("     " + l[:300])
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

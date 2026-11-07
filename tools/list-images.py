"""Lists every container image referenced by rendered Kubernetes YAML.

Usage: python list-images.py [--workloads] <rendered.yaml>...

By default it walks every string of every document, so images that live in
ConfigMaps, arguments and CRs (KServe runtimes, the KFP launcher and driver,
the Argo Workflows executor) are found too. With --workloads it prints only
the images of pod templates (Deployments, StatefulSets, DaemonSets, Jobs):
what the cluster will actually pull at install time.
"""
import re
import sys

import yaml

IMAGE = re.compile(
    r"^(?:[a-z0-9.-]+\.[a-z]{2,}(?::[0-9]+)?/)?[a-z0-9._-]+(?:/[a-z0-9._-]+)*"
    r"(?::[A-Za-z0-9._-]+)?(?:@sha256:[a-f0-9]{64})?$"
)
REGISTRIES = ("docker.io/", "ghcr.io/", "gcr.io/", "quay.io/", "registry.k8s.io/",
              "kserve/", "docker.gitea.com/", "gitea/", "public.ecr.aws/")
BARE = ("mysql:", "postgres:", "python:", "busybox:", "alpine:", "redis:")
WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}


def strings(node):
    if isinstance(node, dict):
        for value in node.values():
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)
    elif isinstance(node, str):
        yield node


def candidates(text):
    # Images also hide inside embedded JSON/YAML strings and command lines.
    for token in re.split(r"[\s\"',=]+", text):
        token = token.strip()
        if (token.startswith(REGISTRIES) or token.startswith(BARE)) and IMAGE.match(token) \
                and (":" in token.split("/")[-1] or "@sha256:" in token):
            yield token


def pod_images(doc):
    spec = (doc.get("spec") or {}).get("template", {}).get("spec", {}) or {}
    for key in ("initContainers", "containers"):
        for container in spec.get(key) or []:
            if container.get("image"):
                yield container["image"]


args = sys.argv[1:]
workloads_only = "--workloads" in args
paths = [a for a in args if a != "--workloads"]
found = set()
for path in paths:
    with open(path, encoding="utf-8") as handle:
        for doc in yaml.safe_load_all(handle):
            if not doc:
                continue
            if workloads_only:
                if doc.get("kind") in WORKLOADS:
                    found.update(pod_images(doc))
                continue
            for text in strings(doc):
                found.update(candidates(text))
for image in sorted(found):
    print(image)

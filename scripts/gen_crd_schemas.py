#!/usr/bin/env python3
"""Generate strict kubeconform JSON schemas for every CRD this repo depends on.

CRD versions are taken from the charts pinned in gitops/ (so validation always
matches what Flux will install), plus Flux's own CRDs.

Usage: scripts/gen_crd_schemas.py <gitops_dir> <out_dir>
Env:   FLUX_VERSION (default "latest"), e.g. v2.7.0
Needs: helm, python3 + PyYAML
"""
from __future__ import annotations

import copy
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

import yaml


class _Loader(yaml.SafeLoader):
    """Some CRDs contain the YAML '=' value tag; treat it as a plain scalar."""


_Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def log(msg: str) -> None:
    print(f"[gen_crd_schemas] {msg}", file=sys.stderr)


def load_docs(text: str) -> list[dict]:
    return [d for d in yaml.load_all(text, Loader=_Loader) if isinstance(d, dict)]


def collect_releases(gitops: pathlib.Path) -> list[tuple[str, str, str]]:
    repos: dict[tuple[str, str], tuple[str, str]] = {}
    releases = []
    for path in sorted(gitops.rglob("*.yaml")):
        for doc in load_docs(path.read_text()):
            kind, meta = doc.get("kind"), doc.get("metadata", {})
            if kind == "HelmRepository":
                spec = doc["spec"]
                repos[(meta.get("namespace", ""), meta["name"])] = (spec["url"], spec.get("type", "default"))
            elif kind == "HelmRelease":
                releases.append((meta.get("namespace", ""), doc["spec"]["chart"]["spec"]))
    out = []
    for namespace, chart in releases:
        ref = chart["sourceRef"]
        key = (ref.get("namespace", namespace), ref["name"])
        if key not in repos:
            # kustomize sets namespace at build time for app layers; fall back to name only.
            matches = [v for k, v in repos.items() if k[1] == ref["name"]]
            if not matches:
                raise SystemExit(f"HelmRepository {key} not found for chart {chart['chart']}")
            url, rtype = matches[0]
        else:
            url, rtype = repos[key]
        out.append((chart["chart"], str(chart["version"]), url if rtype != "oci" else f"{url}/{chart['chart']}"))
    return sorted(set(out))


def render_chart_crds(chart: str, version: str, url: str) -> str:
    cmd = ["helm", "template", "crds", "--include-crds", "--version", version]
    cmd += [url] if url.startswith("oci://") else [chart, "--repo", url]
    log(f"helm template {chart}@{version}")
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def fetch_flux_crds() -> str:
    version = os.environ.get("FLUX_VERSION", "latest")
    url = (
        "https://github.com/fluxcd/flux2/releases/latest/download/install.yaml"
        if version == "latest"
        else f"https://github.com/fluxcd/flux2/releases/download/{version}/install.yaml"
    )
    log(f"fetching Flux CRDs ({version})")
    with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310 - fixed https URL
        return resp.read().decode()


def make_strict(schema):
    if isinstance(schema, dict):
        if (
            "properties" in schema
            and not schema.get("x-kubernetes-preserve-unknown-fields")
            and "additionalProperties" not in schema
        ):
            schema["additionalProperties"] = False
        for key, value in schema.items():
            if key in ("properties", "patternProperties", "definitions"):
                for sub in value.values():
                    make_strict(sub)
            elif isinstance(value, (dict, list)):
                make_strict(value)
    elif isinstance(schema, list):
        for item in schema:
            make_strict(item)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    gitops, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    sources = [fetch_flux_crds()] + [render_chart_crds(*r) for r in collect_releases(gitops)]
    count = 0
    for text in sources:
        for doc in load_docs(text):
            if doc.get("kind") != "CustomResourceDefinition":
                continue
            group = doc["spec"]["group"]
            kind = doc["spec"]["names"]["kind"].lower()
            for ver in doc["spec"]["versions"]:
                schema = copy.deepcopy(ver["schema"]["openAPIV3Schema"])
                make_strict(schema)
                props = schema.setdefault("properties", {})
                props.setdefault("apiVersion", {"type": "string"})
                props.setdefault("kind", {"type": "string"})
                props["metadata"] = {"type": "object"}
                (out / f"{kind}-{group}-{ver['name']}.json").write_text(json.dumps(schema))
                count += 1
    log(f"wrote {count} schemas to {out}")


if __name__ == "__main__":
    main()

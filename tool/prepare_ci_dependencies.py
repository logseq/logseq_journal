#!/usr/bin/env python3
"""Resolve locked Git dependencies once and pin the exact CI checkouts."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

def run(*args):
    print("+", " ".join(args), flush=True)
    subprocess.run(args, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", action="store_true", help="pin previously resolved checkouts")
    args = parser.parse_args()
    report = Path(".ci-reports/dependencies.json")
    if args.pin:
        for record in json.loads(report.read_text()):
            directory = Path(record["checkout"])
            actual = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
            if actual != record["resolved_sha"]:
                raise ValueError(f"resolved checkout changed: {directory}")
            run("opam", "pin", "add", "--yes", "--no-action", "--ignore-pin-depends",
                record["package"], str(directory.resolve()))
        return
    packages = {}
    pattern = re.compile(r'\[\s*"([^"]+)"\s*"git\+([^"]+)"\s*\]')
    for manifest in sorted(Path(".").glob("*.opam.locked")):
        for package, source in pattern.findall(manifest.read_text()):
            previous = packages.setdefault(package, source)
            if previous != source:
                raise ValueError(f"conflicting pins for {package}: {previous} / {source}")
    if not packages:
        raise ValueError("no locked Git dependencies found")

    checkouts = {}
    records = []
    for package, source in sorted(packages.items()):
        if source not in checkouts:
            repository, separator, ref = source.rpartition("#")
            if not separator or not repository.startswith("https://github.com/"):
                raise ValueError(f"expected an explicit public GitHub ref: {source}")
            name = repository.rsplit("/", 1)[-1].removesuffix(".git")
            directory = Path(".ci-deps") / (name + "-" + hashlib.sha256(source.encode()).hexdigest()[:10])
            directory.mkdir(parents=True, exist_ok=True)
            run("git", "init", "--quiet", str(directory))
            run("git", "-C", str(directory), "fetch", "--quiet", "--depth", "1", repository, ref)
            run("git", "-C", str(directory), "checkout", "--quiet", "--detach", "FETCH_HEAD")
            sha = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
            checkouts[source] = (directory, sha)
        directory, sha = checkouts[source]
        records.append({"package": package, "source": "git+" + source, "resolved_sha": sha, "checkout": str(directory)})
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(records, indent=2) + "\n")
    print(report.read_text(), flush=True)
    # --pin uses these exact checkouts after cache restoration; it never
    # re-fetches refs or follows nested pin-depends to a second revision.

if __name__ == "__main__":
    main()

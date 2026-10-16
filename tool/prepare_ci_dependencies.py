#!/usr/bin/env python3
"""Resolve/pin locked CI checkouts or describe their native switch cache identity."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import subprocess

from journal_build import fingerprint, opam_identity, sdk_identity, sha

def run(*args):
    print("+", " ".join(args), flush=True)
    subprocess.run(args, check=True)

def cache_identity(root):
    """Describe a native CI dependency switch; never restore or install anything."""
    root = root.resolve()

    def capture(*args):
        return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.PIPE).strip()

    if (platform.system(), platform.machine(), os.environ.get("RUNNER_OS"), os.environ.get("RUNNER_ARCH")) != ("Darwin", "arm64", "macOS", "ARM64"):
        raise ValueError("CI dependency cache requires a native macOS ARM64 runner")
    image = {name: os.environ.get(name) for name in ("ImageOS", "ImageVersion")}
    if not all(image.values()):
        raise ValueError("runner ImageOS and ImageVersion are required for cache identity")
    identity = opam_identity(lambda *args: capture("opam", *args))
    if "architecture: arm64" not in identity["ocaml"] or "system: macosx" not in identity["ocaml"]:
        raise ValueError("CI dependency cache requires a native arm64 macosx OCaml compiler")
    manifests = sorted(root.glob("*.opam*"))
    if not any(p.name.endswith(".opam.locked") for p in manifests):
        raise ValueError("locked dependency manifests are required for cache identity")
    resolved = json.loads((root / ".ci-reports/dependencies.json").read_text())
    if not resolved or any(not re.fullmatch(r"[0-9a-f]{40}", record["resolved_sha"]) for record in resolved):
        raise ValueError("exact resolved dependency SHAs are required for cache identity")
    sdk = capture("xcrun", "--sdk", "macosx", "--show-sdk-path")
    clang = capture("xcrun", "--sdk", "macosx", "--find", "clang")
    gmp = Path(capture("pkg-config", "--variable=libdir", "gmp")) / "libgmp.a"
    system_libraries = {}
    for name in ("gmp", "sqlite3", "zlib"):
        directory = Path(capture("pkg-config", "--variable=libdir", name))
        library = "z" if name == "zlib" else name
        headers = Path(capture("pkg-config", "--variable=includedir", name))
        header_names = {"gmp": ("gmp.h",), "sqlite3": ("sqlite3.h", "sqlite3ext.h"),
                        "zlib": ("zlib.h", "zconf.h")}[name]
        inputs = [p for p in directory.glob("lib" + library + "*")
                  if p.suffix in {".a", ".dylib", ".tbd"} and p.is_file()]
        inputs += [headers / h for h in header_names if (headers / h).is_file()]
        system_libraries[name] = {"version": capture("pkg-config", "--modversion", name),
            "flags": capture("pkg-config", "--cflags", "--libs", name),
            "files": {str(p): sha(p) for p in sorted(inputs)}}
    recipe = [root / name for name in (".github/workflows/ci.yml", "tool/prepare_ci_dependencies.py", "tool/journal_build.py")]
    identity.update(schema_version=2, host=dict(system=platform.system(), architecture=platform.machine(),
                    release=platform.release(), image=image),
                    workspace=str(root), opam_root=str(Path(capture("opam", "var", "root")).resolve()),
                    opam_version=capture("opam", "--version"), resolved=resolved,
                    manifests={p.name: sha(p) for p in manifests},
                    recipe={str(p.relative_to(root)): sha(p) for p in recipe},
                    xcode=capture("xcodebuild", "-version"), sdk_path=sdk,
                    sdk=sdk_identity(sdk, "macosx", capture("xcrun", "--sdk", "macosx", "--show-sdk-version")),
                    clang={"path": clang, "sha256": sha(clang)},
                    gmp={"path": str(gmp), "sha256": sha(gmp)}, system_libraries=system_libraries,
                    environment={name: os.environ.get(name) for name in
                        ("PATH", "DEVELOPER_DIR", "SDKROOT", "CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS",
                         "LDFLAGS", "PKG_CONFIG_PATH", "OCAMLPARAM", "MACOSX_DEPLOYMENT_TARGET")})
    return {"key": fingerprint(identity), "identity": identity}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--pin", action="store_true", help="pin previously resolved checkouts")
    mode.add_argument("--cache-identity", action="store_true", help="record native CI switch identity without installing")
    args = parser.parse_args()
    if args.cache_identity:
        report = Path(".ci-reports/opam-cache.json")
        report.write_text(json.dumps(cache_identity(Path.cwd()), indent=2) + "\n")
        print(report.read_text(), end="")
        return
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

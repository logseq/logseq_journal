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
import shutil
import tempfile

from journal_build import fingerprint, opam_identity, sdk_identity, sha

def run(*args):
    print("+", " ".join(args), flush=True)
    subprocess.run(args, check=True)

def cache_identity(root, lookup_path=None):
    """Describe build inputs before any switch/compiler exists; never provision."""
    root = root.resolve()

    def capture(*args):
        return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.PIPE).strip()

    if (platform.system(), platform.machine(), os.environ.get("RUNNER_OS"), os.environ.get("RUNNER_ARCH")) != ("Darwin", "arm64", "macOS", "ARM64"):
        raise ValueError("CI dependency cache requires a native macOS ARM64 runner")
    image = {name: os.environ.get(name) for name in ("ImageOS", "ImageVersion")}
    if not all(image.values()):
        raise ValueError("runner ImageOS and ImageVersion are required for cache identity")
    compiler = os.environ.get("CI_COMPILER", "")
    repository = os.environ.get("CI_OPAM_REPOSITORY", "")
    if not re.fullmatch(r"ocaml-base-compiler\.[0-9]+\.[0-9]+\.[0-9]+", compiler):
        raise ValueError("an exact vanilla CI_COMPILER is required")
    if not re.fullmatch(r"git\+https://github.com/ocaml/opam-repository.git#[0-9a-f]{40}", repository):
        raise ValueError("an exact compiler/package recipe repository commit is required")
    opam_version = os.environ.get("CI_OPAM_VERSION", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", opam_version):
        raise ValueError("an exact CI_OPAM_VERSION is required")
    identity = dict(opam_prefix=str(root / "_opam"), compiler=compiler,
                    compiler_repository=repository, opam_version=opam_version)
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
    for name in ("gmp", "sqlite3", "zlib", "libzstd"):
        directory = Path(capture("pkg-config", "--variable=libdir", name))
        library = {"zlib": "z", "libzstd": "zstd"}.get(name, name)
        headers = Path(capture("pkg-config", "--variable=includedir", name))
        header_names = {"gmp": ("gmp.h",), "sqlite3": ("sqlite3.h", "sqlite3ext.h"),
                        "zlib": ("zlib.h", "zconf.h"), "libzstd": ("zstd.h",)}[name]
        inputs = [p for p in directory.glob("lib" + library + "*")
                  if p.suffix in {".a", ".dylib", ".tbd"} and p.is_file()]
        if not inputs or any(not (headers / h).is_file() for h in header_names):
            raise ValueError(f"missing native library/header inputs: {name}")
        inputs += [headers / h for h in header_names]
        system_libraries[name] = {"version": capture("pkg-config", "--modversion", name),
            "flags": capture("pkg-config", "--cflags", "--libs", name),
            "files": {str(p): sha(p) for p in sorted(inputs)}}
    recipe = [root / name for name in (".github/workflows/ci.yml", ".agents/skills/journal-build/scripts/prepare_ci_dependencies.py", ".agents/skills/journal-build/scripts/journal_build.py")]
    identity.update(schema_version=3, host=dict(system=platform.system(), architecture=platform.machine(),
                    release=platform.release(), build=capture("sw_vers", "-buildVersion"), image=image),
                    workspace=str(root), opam_root=str(Path(os.environ.get("OPAMROOT", Path.home() / ".opam")).resolve()),
                    resolved=resolved,
                    manifests={p.name: sha(p) for p in manifests},
                    recipe={str(p.relative_to(root)): sha(p) for p in recipe},
                    xcode=capture("xcodebuild", "-version"), sdk_path=sdk,
                    sdk=sdk_identity(sdk, "macosx", capture("xcrun", "--sdk", "macosx", "--show-sdk-version")),
                    clang={"path": clang, "sha256": sha(clang)},
                    gmp={"path": str(gmp), "sha256": sha(gmp)}, system_libraries=system_libraries,
                    environment={name: os.environ.get(name) for name in
                        ("PATH", "DEVELOPER_DIR", "SDKROOT", "CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS",
                         "LDFLAGS", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "OCAMLPARAM", "MACOSX_DEPLOYMENT_TARGET",
                         "OCAMLLIB", "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
                         "CAML_LD_LIBRARY_PATH", "ARCHFLAGS",
                         "OPAMJOBS", "OPAMEXTERNALSOLVER", "OPAMPRECISETRACKING", "OPAMCRITERIA",
                         "OCAML_CONFIGURE_OPTIONS")})
    if lookup_path is not None:
        # setup-ocaml only prepends its opam executable to PATH. All actual
        # compiler/SDK/library selections above are freshly observed.
        identity["environment"]["PATH"] = lookup_path
    return {"key": fingerprint(identity), "identity": identity}


def cache_files(report):
    """Critical restored state checked without executing the cached compiler."""
    identity = report["identity"]
    prefix, opam_root = Path(identity["opam_prefix"]), Path(identity["opam_root"])
    required = [prefix / "bin/ocamlopt.opt", prefix / ".opam-switch/switch-config",
                prefix / ".opam-switch/switch-state", opam_root / "config"]
    optional = list((prefix / "bin").glob("ocaml*"))
    optional += list((prefix / ".opam-switch/packages").glob("ocaml*/opam"))
    return {str(p): sha(p) for p in sorted(set(required + [p for p in optional if p.is_file()]))}


def cache_receipt(report, opam):
    identity = report["identity"]
    observed = opam_identity(opam)
    version = identity["compiler"].removeprefix("ocaml-base-compiler.")
    if (observed["opam_prefix"] != identity["opam_prefix"] or
        not all(field in observed["ocaml"].splitlines() for field in
                ("version: " + version, "architecture: arm64", "system: macosx")) or
        opam("--version") != identity["opam_version"]):
        raise ValueError("installed compiler/opam differs from requested CI inputs")
    return dict(inputs=report, compiler=observed, files=cache_files(report))


def validate_restored_cache(report, exact_hit):
    try:
        if not exact_hit:
            raise ValueError("no exact Actions cache hit")
        receipt = json.loads((Path(report["identity"]["opam_prefix"]) / ".journal-ci-cache.json").read_text())
        if receipt["inputs"] != report or receipt["files"] != cache_files(report):
            raise ValueError("restored input identity or compiler/switch metadata differs")
        return dict(status="accepted", compiler=receipt["compiler"])
    except (OSError, ValueError, KeyError, TypeError) as error:
        return dict(status="rejected", reason=str(error))


def quarantine_cache(report):
    """Move rejected state only on the workflow's disposable hosted runner."""
    identity = report["identity"]
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve()
    prefix, opam_root = Path(identity["opam_prefix"]), Path(identity["opam_root"])
    if (os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
        prefix != workspace / "_opam" or opam_root != Path.home() / ".opam" or
        prefix.is_symlink() or opam_root.is_symlink()):
        raise ValueError("refusing to move non-owned CI cache paths")
    destination = Path(tempfile.mkdtemp(prefix="journal-rejected-cache-", dir=os.environ["RUNNER_TEMP"]))
    for name, path in (("switch", prefix), ("root", opam_root)):
        if path.exists():
            shutil.move(str(path), str(destination / name))
    return str(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--pin", action="store_true", help="pin previously resolved checkouts")
    mode.add_argument("--cache-identity", action="store_true", help="record CI build-input identity before compiler setup")
    mode.add_argument("--validate-cache", action="store_true", help="validate exact restored state or quarantine for cold setup")
    mode.add_argument("--seal-cache", action="store_true", help="verify final native inputs and record restored-state receipt")
    args = parser.parse_args()
    if args.validate_cache or args.seal_cache:
        report = json.loads(Path(".ci-reports/opam-cache.json").read_text())
        if args.validate_cache:
            result = validate_restored_cache(report, os.environ.get("CI_CACHE_HIT") == "true")
            if result["status"] != "accepted":
                result["quarantine"] = quarantine_cache(report)
            Path(".ci-reports/cache-restore.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result, indent=2))
        else:
            if cache_identity(Path.cwd(), lookup_path=report["identity"]["environment"]["PATH"]) != report:
                raise ValueError("native CI inputs changed after lookup; refusing to save switch")
            def opam(*argv):
                return subprocess.check_output(["opam", *argv], text=True).strip()
            receipt = cache_receipt(report, opam)
            path = Path(report["identity"]["opam_prefix"]) / ".journal-ci-cache.json"
            path.write_text(json.dumps(receipt, indent=2) + "\n")
            Path(".ci-reports/cache-receipt.json").write_bytes(path.read_bytes())
        return
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

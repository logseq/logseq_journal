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
import shlex
import tempfile

from journal_build import fingerprint, opam_identity, sdk_identity, sha
from ci_native_compatibility import (native_link_checks, probe_compiler, probe_sqlite_binding, probe_zarith_binding, require_native_symbols)

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
    # Deliberate schema changes govern the bootstrap contract. Comments and
    # reporting-only helper edits do not change an installed compiler's ABI.
    setup = re.findall(r"uses: ocaml/setup-ocaml@([0-9a-f]{40})", (root / ".github/workflows/ci.yml").read_text())
    if len(setup) != 1:
        raise ValueError("one pinned setup-ocaml action is required")
    tools = {}
    for name, override in (("cc", "CC"), ("c++", "CXX"), ("make", "MAKE"), ("ar", "AR"), ("ranlib", "RANLIB"), ("ld", "LD")):
        argv = shlex.split(os.environ.get(override) or name)
        selected = shutil.which(argv[0])
        if not selected:
            raise ValueError("missing build tool: " + name)
        tools[name] = dict(path=str(Path(selected).resolve()), sha256=sha(selected), arguments=fingerprint(argv[1:]))
    flags = ("SDKROOT", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "OCAMLPARAM",
             "MACOSX_DEPLOYMENT_TARGET", "OCAMLLIB", "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH",
             "CPLUS_INCLUDE_PATH", "CAML_LD_LIBRARY_PATH", "ARCHFLAGS", "OPAMJOBS", "OPAMEXTERNALSOLVER",
             "OPAMPRECISETRACKING", "OPAMCRITERIA", "OCAML_CONFIGURE_OPTIONS")
    identity.update(schema_version=4, setup_action=setup[0],
                    host=dict(system=platform.system(), architecture=platform.machine(), os_major=platform.mac_ver()[0].split('.')[0]),
                    workspace=str(root), opam_root=str(Path(os.environ.get("OPAMROOT", Path.home() / ".opam")).resolve()),
                    resolved=resolved, manifests={p.name: sha(p) for p in manifests},
                    xcode=capture("xcodebuild", "-version"), sdk_path=sdk,
                    sdk=sdk_identity(sdk, "macosx", capture("xcrun", "--sdk", "macosx", "--show-sdk-version")),
                    clang={"path": clang, "sha256": sha(clang)}, tools=tools,
                    environment={name: fingerprint(os.environ[name]) if name in os.environ else None for name in flags})
    observed = dict(image=image, release=platform.release(), build=capture("sw_vers", "-buildVersion"),
                    path_sha256=fingerprint(lookup_path if lookup_path is not None else os.environ.get("PATH")),
                    system_libraries=system_libraries)
    return {"key": fingerprint(identity), "native_key": fingerprint(system_libraries), "identity": identity, "observed": observed}


def cache_key(report):
    return "journal-opam-v4-macOS-ARM64-" + report["key"] + "-" + report["native_key"]


def differences(cached, current, field=""):
    if isinstance(cached, dict) and isinstance(current, dict):
        return [item for name in sorted(set(cached) | set(current))
                for item in differences(cached.get(name), current.get(name), field + "." + name)]
    if cached == current:
        return []
    return [dict(field=field.lstrip("."), cached=cached, current=current)]


def safe_log(value, field=""):
    """Logs contain hashes for environment values and no personal absolute paths."""
    if isinstance(value, dict):
        if {"field", "cached", "current"} <= value.keys():
            return dict(field=safe_log(value["field"]), cached=safe_log(value["cached"], value["field"]), current=safe_log(value["current"], value["field"]))
        return {safe_log(k): safe_log(v, field + "." + k) for k, v in value.items()}
    if isinstance(value, list):
        return [safe_log(v, field) for v in value]
    if isinstance(value, str):
        if ".environment." in field and not re.fullmatch(r"[0-9a-f]{64}", value):
            return "sha256:" + fingerprint(value)
        return re.sub(r"/Users/[^/\s]+", "/Users/<user>", value)
    return value


def comparable_record(record):
    return (isinstance(record, dict) and isinstance(record.get("identity"), dict)
            and isinstance(record.get("observed", {}), dict)
            and isinstance(record.get("observed", {}).get("system_libraries", {}), dict))


def cache_diagnostics(current, cached, status, reason):
    if not comparable_record(cached):
        cached = None
    changes = differences(cached.get("identity", {}), current["identity"], "identity") if cached else []
    native = differences(cached.get("observed", {}).get("system_libraries", {}),
                         current.get("observed", {}).get("system_libraries", {}), "native") if cached else []
    audit = differences({k: v for k, v in cached.get("observed", {}).items() if k != "system_libraries"},
                        {k: v for k, v in current.get("observed", {}).items() if k != "system_libraries"}, "audit") if cached else []
    return safe_log(dict(status=status, reason=reason, comparison_available=cached is not None,
                         comparison_reason="recorded candidate inputs" if cached else "no readable prior manifest; differences unavailable",
                         current=current, differences=changes, native_changes=native, ignored_audit_changes=audit))


def cache_files(report, allow_missing=False):
    """Critical restored state checked without executing the cached compiler."""
    identity = report["identity"]
    prefix, opam_root = Path(identity["opam_prefix"]), Path(identity["opam_root"])
    required = [prefix / "bin/ocamlopt.opt", prefix / ".opam-switch/switch-config",
                prefix / ".opam-switch/switch-state", opam_root / "config"]
    optional = list((prefix / "bin").glob("ocaml*"))
    optional += list((prefix / ".opam-switch/packages").glob("ocaml*/opam"))
    return {str(p): sha(p) if p.is_file() or not allow_missing else None
            for p in sorted(set(required + [p for p in optional if p.is_file()]))}


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


def validate_restored_cache(report, exact_hit, matched_key=""):
    cached = None
    file_changes = []
    try:
        if not exact_hit and not matched_key:
            raise ValueError("no accessible compatible switch archive")
        receipt = json.loads((Path(report["identity"]["opam_prefix"]) / ".journal-ci-cache.json").read_text())
        cached = receipt["inputs"]
        if not comparable_record(cached):
            raise ValueError("invalid restored input manifest structure")
        if cached["key"] != report["key"] or cached["identity"] != report["identity"]:
            raise ValueError("compatibility input mismatch")
        if matched_key and matched_key != cache_key(cached):
            raise ValueError("Actions matched key differs from switch receipt")
        file_changes = differences(receipt["files"], cache_files(report, allow_missing=True), "files")
        if file_changes:
            raise ValueError("compiler/switch metadata hash mismatch")
        result = cache_diagnostics(report, cached, "accepted", "receipt accepted; native probes still required")
        result.update(source="exact" if exact_hit and cached["native_key"] == report["native_key"] else "compatible", compiler=receipt["compiler"])
        return result
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = cache_diagnostics(report, cached, "rejected", str(error))
        result["differences"].extend(safe_log(file_changes))
        return result


def rebuild_native_packages(packages, opam):
    installed = set(opam("list", "--installed", "--short", "--color=never").splitlines())
    roots = sorted(set(packages) & installed)
    if roots:
        # opam computes and rebuilds the real reverse dependency closure.
        opam("reinstall", "--locked", "--ignore-pin-depends", "--yes", *roots)
    return roots


def check_native(report, opam, repair=False):
    prefix = Path(report["identity"]["opam_prefix"])
    checks, roots = native_link_checks(prefix, report["observed"]["system_libraries"])
    sqlite = None
    if (prefix / "lib/sqlite3/sqlite3.cmxa").exists():
        try:
            # Fixture runs must demonstrate the selected different provider was
            # actually loaded. Normal runs validate the real install-name provider.
            expected = report["observed"]["system_libraries"]["sqlite3"]["version"] if os.environ.get("CI_SQLITE_PROFILE", "brew") != "brew" else None
            sqlite = probe_sqlite_binding(prefix, expected)
        except RuntimeError as error:
            roots = sorted(set(roots) | {"sqlite3"})
            checks.append(dict(group="sqlite3", status="rebuild", reason=str(error)))
    zarith = None
    if (prefix / "lib/zarith/zarith.cmxa").exists():
        try:
            zarith = probe_zarith_binding(prefix)
        except RuntimeError as error:
            roots = sorted(set(roots) | {"zarith"})
            checks.append(dict(group="gmp", status="rebuild", reason=str(error)))
    result = dict(status="compatible" if not roots else "repair-required", checks=checks, sqlite=sqlite, zarith=zarith, rebuild_roots=roots)
    print(json.dumps(safe_log(result), indent=2), flush=True)
    if roots:
        if not repair:
            raise RuntimeError("native compatibility failed after repair: " + ", ".join(roots))
        result["reinstalled_roots"] = rebuild_native_packages(roots, opam)
        result["after_repair"] = check_native(report, opam, repair=False)
        result["status"] = "repaired"
    return result


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
    mode.add_argument("--validate-cache", action="store_true", help="validate compatible restored state or quarantine for cold setup")
    mode.add_argument("--check-native-cache", action="store_true", help="probe restored bindings; repair only incompatible native packages")
    mode.add_argument("--seal-cache", action="store_true", help="verify final native inputs and record restored-state receipt")
    args = parser.parse_args()
    if args.validate_cache or args.seal_cache or args.check_native_cache:
        report = json.loads(Path(".ci-reports/opam-cache.json").read_text())
        def opam(*argv):
            command = ["opam", *argv]
            print("+", " ".join(command), flush=True)
            output = subprocess.check_output(command, text=True).strip()
            if argv[0] == "reinstall":
                print(output, flush=True)
            return output
        if args.validate_cache:
            result = validate_restored_cache(report, os.environ.get("CI_CACHE_HIT") == "true", os.environ.get("CI_CACHE_MATCHED_KEY", ""))
            if not result["comparison_available"]:
                try:
                    candidate = json.loads(Path(".ci-reports/cache-candidate/inputs.json").read_text())
                    result = cache_diagnostics(report, candidate, "rejected", result["reason"])
                except (OSError, ValueError, TypeError, KeyError):
                    pass
            if result["status"] == "accepted":
                try:
                    result["compiler_probe"] = probe_compiler(report["identity"]["opam_prefix"])
                except RuntimeError as error:
                    result.update(status="rejected", reason="restored compiler probe failed: " + str(error))
            if result["status"] != "accepted":
                result["quarantine"] = quarantine_cache(report)
            Path(".ci-reports/cache-restore.json").write_text(json.dumps(safe_log(result), indent=2) + "\n")
            print(json.dumps(safe_log(result), indent=2))
        elif args.check_native_cache:
            restored = json.loads(Path(".ci-reports/cache-restore.json").read_text())
            if restored["status"] != "accepted":
                print('Native reuse check: cold setup; installed-state probes run during sealing')
                return
            result = check_native(report, opam, repair=True)
            Path(".ci-reports/native-compatibility.json").write_text(json.dumps(safe_log(result), indent=2) + "\n")
        else:
            final = cache_identity(Path.cwd())
            # PATH prefixes introduced by setup are audit-only; selected tools,
            # flags, native providers and all compatibility inputs are reobserved.
            if final["key"] != report["key"] or final["native_key"] != report["native_key"]:
                print(json.dumps(cache_diagnostics(final, report, "rejected", "inputs changed during build"), indent=2))
                raise ValueError("CI inputs changed after lookup; refusing to save switch")
            native = check_native(report, opam)
            Path(".ci-reports/native-final.json").write_text(json.dumps(safe_log(native), indent=2) + "\n")
            receipt = cache_receipt(report, opam)
            path = Path(report["identity"]["opam_prefix"]) / ".journal-ci-cache.json"
            path.write_text(json.dumps(receipt, indent=2) + "\n")
            Path(".ci-reports/cache-receipt.json").write_bytes(path.read_bytes())
            candidate = Path(".ci-reports/cache-candidate/inputs.json")
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.write_text(json.dumps(report, indent=2) + "\n")
        return
    if args.cache_identity:
        report = Path(".ci-reports/opam-cache.json")
        inputs = cache_identity(Path.cwd())
        report.write_text(json.dumps(inputs, indent=2) + "\n")
        print(json.dumps(safe_log(inputs), indent=2))
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

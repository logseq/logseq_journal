#!/usr/bin/env python3
"""Implementation of build_journal_apple.sh. Python standard library only."""
import argparse
from contextlib import contextmanager, ExitStack
from datetime import datetime, timezone
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[4]


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def opam_identity(opam):
    """Describe the selected compiler without provisioning or accepting dependencies."""
    prefix = Path(opam("var", "prefix")).resolve()
    compiler = prefix / "bin/ocamlopt.opt"
    return {"opam_prefix": str(prefix),
            "ocaml": opam("exec", "--", str(compiler), "-config"),
            "compiler_sha256": sha(compiler)}


def read_evidence(record, directory):
    path = (directory / record["path"]).resolve()
    if sha(path) != record["sha256"]:
        raise ValueError(f"producer evidence hash mismatch: {path}")
    return json.loads(path.read_text())


def sdk_identity(sdk, platform, version):
    path = Path(sdk) / "SDKSettings.plist"
    settings = plistlib.loads(path.read_bytes())
    if settings["DefaultProperties"]["PLATFORM_NAME"] != platform or settings["Version"] != version:
        raise ValueError(f"SDK platform/version differs from selected {platform} {version}: {sdk}")
    return {"settings": {str(path): sha(path)}, "canonical_name": settings["CanonicalName"]}


def files(directory, native_only=False):
    """Hash input bytes, including untracked edits, without traversing caches."""
    ignored = {".git", ".build", "_build", "node_modules", "__pycache__"}
    result = {}
    for parent, dirs, names in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d not in ignored and not d.startswith(".ci-"))
        for name in sorted(names):
            path = Path(parent) / name
            native = path.suffix in {".a", ".cmxa", ".cmx", ".cmi", ".cma", ".o", ".so", ".dylib", ".h"} or name in {"META", "dune-package"}
            if path.is_file() and not name.endswith(".pyc") and (not native_only or native):
                result[str(path.relative_to(directory))] = sha(path)
    return result


def source_inputs():
    result = {}
    for path in sorted(ROOT.iterdir()):
        if path.name in {"app", "swift", "apple", "assets", "config", "tool"} or path.name.startswith("logseq_"):
            if path.is_dir():
                result.update({str(path.relative_to(ROOT) / name): digest
                               for name, digest in files(path).items()})
            elif path.is_file():
                result[path.name] = sha(path)
        elif path.name in {"dune-project", "dune", "dune-workspace"}:
            result[path.name] = sha(path)
    skill_scripts = ROOT / ".agents/skills/journal-build/scripts"
    result.update({str(skill_scripts.relative_to(ROOT) / name): digest
                   for name, digest in files(skill_scripts).items()})
    return result


@contextmanager
def resource_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            stream.seek(0)
            raise RuntimeError(f"busy: {path}: {stream.read().strip()}") from None
        stream.seek(0)
        stream.truncate()
        stream.write(f"pid={os.getpid()} cwd={ROOT}\n")
        stream.flush()
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


class Build:
    def __init__(self, args, run_dir):
        self.args = args
        self.run_dir = run_dir
        self.phase = "preflight"
        self.env = dict(os.environ)
        # Xcode's Python launcher inserts SDK/include/library lookup variables.
        # They must not affect the explicit target SDK or switch in subprocesses.
        ignored = {name: self.env.pop(name) for name in ("SDKROOT", "CPATH", "LIBRARY_PATH",
                   "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH") if name in self.env}
        mode = ("native-producer" if getattr(args, "producer_only", False) else
                "probe-object" if getattr(args, "probe_native_object", None) else
                "experimental-host-restamp" if args.experimental_host_restamp else "link-only" if args.link_only else "native")
        self.report = {"status": "running", "started": datetime.now(timezone.utc).isoformat(),
                       "commands": [], "mode": mode, "cross_abi_validated": False,
                       "runtime_acceptance": False, "installed": False, "ignored_environment": ignored}

    def save(self):
        (self.run_dir / "manifest.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def run(self, *argv, cwd=ROOT, env=None):
        argv = [str(a) for a in argv]
        record = {"phase": self.phase, "argv": argv, "cwd": str(cwd),
                  "started": datetime.now(timezone.utc).isoformat()}
        self.report["commands"].append(record)
        log = self.run_dir / (self.phase + ".log")
        print(f"[{self.phase}] {shlex.join(argv)}", file=sys.stderr, flush=True)
        # Stream output directly to the phase log, including while a compiler is running.
        with log.open("a+") as stream:
            stream.write("+ " + shlex.join(argv) + "\n")
            stream.flush()
            offset = stream.tell()
            process = subprocess.Popen(argv, cwd=cwd, env=env or self.env, text=True,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait()
            except BaseException:
                # Keep locks until this command's descendants have stopped.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
                finally:
                    # The leader may exit before a descendant that ignores SIGTERM.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                raise
            stream.seek(offset)
            output = stream.read()
        record.update(exit_code=code, finished=datetime.now(timezone.utc).isoformat())
        self.save()
        if code:
            raise RuntimeError(f"{self.phase}: exit {code}; see {log}\n{output[-3000:]}")
        return output.strip()

    def opam(self, *argv):
        return self.run("opam", argv[0], "--switch", self.args.switch, *argv[1:])

    def dependencies(self):
        rows = [line.split(maxsplit=2) for line in self.opam(
            "list", "--installed", "--columns=name,installed-version,pin", "--short", "--color=never").splitlines()]
        installed = {row[0]: row[1] for row in rows}
        current_pins = {row[0]: row[2] for row in rows if len(row) == 3}
        wanted, pins = {}, {}
        for lock in sorted(ROOT.glob("*.opam.locked")):
            text = lock.read_text()
            for package, version in re.findall(r'"([^"\s]+)"\s*\{=\s*"([^"\s]+)"\}', text.split("depends: [", 1)[1]):
                if package in wanted and wanted[package] != version:
                    raise RuntimeError(f"conflicting locked versions: {package}")
                wanted[package] = version
            for package, url in re.findall(r'\[\s*"([^"]+)"\s*"(git\+[^"]+)"\s*\]', text):
                if package in pins and pins[package] != url:
                    raise RuntimeError(f"conflicting locked pins: {package}")
                pins[package] = url
        local = {p.stem for p in ROOT.glob("*.opam")}
        errors = [f"{name}: lock={version}, installed={installed.get(name, 'missing')}"
                  for name, version in wanted.items() if name not in local and installed.get(name) != version]
        resolved = {}
        # Both URL pins and CI's resolved local pins must resolve to a clean Git checkout.
        ci_path = ROOT / ".ci-reports/dependencies.json"
        ci = {r["package"]: r for r in json.loads(ci_path.read_text())} if ci_path.exists() else {}
        for package, expected in pins.items():
            name, version = package.split(".", 1)
            if installed.get(name) != version:
                continue
            metadata = self.prefix / ".opam-switch/packages" / package / "opam"
            actual = current_pins.get(name, "")
            installed_source = self.opam("show", "--just-file", "--field=url.src", metadata).strip('"')
            # Raw source metadata may omit url; the pin belongs to switch state.
            # When recorded, installed provenance must still agree with that state.
            if installed_source and installed_source != actual:
                errors.append(f"{name}: active pin {actual!r} differs from installed source {installed_source!r}")
            checkout = self.prefix / ".opam-switch/sources" / name
            ref = expected.rsplit("#", 1)[1]
            if actual != expected:
                record = ci.get(package, {})
                checkout = (ROOT / record.get("checkout", "missing-ci-checkout")).resolve()
                # A local pin needs the existing CI resolution record, including exact source URL.
                target = urlsplit(actual.removeprefix("git+"))
                local_path = unquote(target.path) if target.scheme == "file" and not target.netloc else actual
                if record.get("source") != expected or local_path != str(checkout):
                    errors.append(f"{name}: active pin {actual!r} differs from lock {expected!r}")
                    continue
                resolved_sha = record.get("resolved_sha", "")
                if not re.fullmatch(r"[0-9a-f]{40}", resolved_sha):
                    errors.append(f"{name}: invalid CI resolved_sha")
                    continue
                if re.fullmatch(r"[0-9a-f]{40}", ref) and resolved_sha != ref:
                    errors.append(f"{name}: CI resolution differs from locked commit {ref}")
                    continue
                if target.fragment:
                    selected = self.run("git", "-C", checkout, "rev-parse", "--verify", "--end-of-options",
                                        unquote(target.fragment) + "^{commit}")
                    if selected != resolved_sha:
                        errors.append(f"{name}: active local pin selects {selected}, CI resolved {resolved_sha}")
                        continue
                ref = resolved_sha
            if not (checkout / ".git").exists():
                errors.append(f"{name}: resolved source checkout missing: {checkout}")
                continue
            try:
                head = self.run("git", "-C", checkout, "rev-parse", "HEAD")
                dirty = self.run("git", "-C", checkout, "status", "--porcelain", "--untracked-files=no")
            except RuntimeError as error:
                errors.append(f"{name}: invalid resolved source checkout: {error}")
                continue
            if dirty or (re.fullmatch(r"[0-9a-f]{40}", ref) and head != ref):
                errors.append(f"{name}: dirty or wrong resolved source: {head}; expected {ref}")
            resolved[package] = {"source": expected, "active_pin": actual,
                                 "resolved_sha": head, "checkout": str(checkout)}
        self.report["dependency_errors"] = errors
        self.report["dependencies"] = {"installed": installed, "pins": resolved,
            "freshness": "offline: moving refs use the currently installed resolved checkout; no remote update"}
        if errors:
            raise RuntimeError("switch/lock mismatch (no pins changed):\n" + "\n".join(errors))
        # Include installed native archives, stubs, interfaces and META in ABI identity.
        self.report["dependencies"]["installed_lib_hashes"] = files(self.prefix / "lib", native_only=True)
        return self.report["dependencies"]

    @staticmethod
    def valid_ocaml_units(units):
        return (isinstance(units, dict) and set(units) == {"runtime", "mldoc", "xmlm"}
                and all(type(value) is bool for value in units.values())
                and units["runtime"] and units["mldoc"])

    def verify_ocaml_units(self, product, *, require_xmlm):
        symbols = self.run("nm", "-j", "-U", product)
        def present(unit):
            return bool(re.search(r"^_caml" + unit + r"(?:__|_|\$|$)", symbols, re.MULTILINE))
        units = {"runtime": "_caml_startup" in symbols.splitlines(),
                 "mldoc": present("Mldoc"), "xmlm": present("Xmlm")}
        if not self.valid_ocaml_units(units) or (require_xmlm and not units["xmlm"]):
            raise ValueError("native object must retain OCaml runtime and mldoc"
                             + (" and legacy XMLm" if require_xmlm else ""))
        undefined = self.run("nm", "-j", "-u", product)
        if re.search(r"^_camlXmlm(?:__|_|\$|$)", undefined, re.MULTILINE):
            raise ValueError("native object contains unresolved XMLm references")
        return units

    @staticmethod
    def native_input_name(name):
        path = Path(name)
        if not path.is_absolute() or ".." in path.parts:
            raise ValueError(f"native input identity needs an absolute path without parent traversal: {name}")
        # The recorded pathname is historical identity. Resolving a symlink
        # again after its removal/retargeting would change that identity.
        return os.path.normpath(str(path))

    @staticmethod
    def bind_native_inputs(inputs, additions):
        for name, digest in additions.items():
            path = Build.native_input_name(name)
            if path in inputs and inputs[path] != digest:
                raise ValueError(f"conflicting native input hash identity: {path}")
            inputs[path] = digest

    def ordinary_native_inputs(self, pre, link):
        """Bind the expanded producer argv to hashed real inputs, without executing it."""
        command = link["command"]
        cwd = Path(link["working_directory"])
        if (not command or not all(isinstance(arg, str) for arg in command)
                or not cwd.is_absolute() or not Path(command[0]).is_absolute()
                or "-output-complete-obj" not in command or command.count("-o") != 1):
            raise ValueError("ordinary producer needs an expanded complete-object command and absolute compiler/cwd")
        def absolute(arg):
            path = Path(arg)
            return self.native_input_name(path if path.is_absolute() else cwd / path)
        output_index = command.index("-o") + 1
        if output_index == len(command) or absolute(command[output_index]) != self.native_input_name(pre["production_native_object"]):
            raise ValueError("native command output differs from the producer object")
        recorded = link["direct_native_input_sha256"]
        if (any(not Path(path).is_absolute() for path in recorded)
                or any(not re.fullmatch(r"[0-9a-f]{64}", digest) for digest in recorded.values())):
            raise ValueError("native input digest is invalid")
        canonical = {absolute(path): digest for path, digest in recorded.items()}
        if len(canonical) != len(recorded) or absolute(command[output_index]) in canonical:
            raise ValueError("native input identities alias each other or the output")
        actual, normalized = set(), [command[0]]
        def native_input(arg, suffixes):
            suffix = Path(arg).suffix
            if arg.startswith(("@", "-")) or suffix not in suffixes:
                raise ValueError(f"unsupported native input argument: {arg}")
            path = absolute(arg)
            actual.add(path)
            required = {path}
            if suffix in {".cmxa", ".cmx"}:
                required.add(str(Path(path).with_suffix(".a" if suffix == ".cmxa" else ".o")))
            if not required.issubset(canonical):
                raise ValueError(f"actual native link input is not hash-bound: {arg}")
            return path
        # Object-only Dune argv. Unknown compiler/linker flags cannot introduce
        # source, plugins, response files or unrecorded -l providers.
        switches = {"-output-complete-obj", "-g", "-strict-sequence", "-strict-formats",
                    "-short-paths", "-keep-locs"}
        index = 1
        while index < len(command):
            arg = command[index]
            if arg in switches:
                normalized.append(arg); index += 1
            elif arg in {"-w", "-warn-error", "-I", "-o", "-cclib"}:
                if index + 1 == len(command):
                    raise ValueError(f"native argument needs a value: {arg}")
                value = command[index + 1]
                if arg in {"-I", "-o"}:
                    value = absolute(value)
                elif arg == "-cclib":
                    if re.search(r"[\s'\"\\]", value):
                        raise ValueError("native -cclib input must be one unquoted token")
                    if value.startswith("-L") and len(value) > 2:
                        value = "-L" + absolute(value[2:])
                    else:
                        value = native_input(value, {".a", ".o"})
                normalized.extend([arg, value]); index += 2
            elif arg.startswith("-"):
                raise ValueError(f"unsupported native compiler/linker argument: {arg}")
            else:
                normalized.append(native_input(arg, {".cmxa", ".cmx", ".a", ".o"})); index += 1
        self.ordinary_command = normalized
        for name in ("mldoc", "xmlm"):
            dependency = link["new_dependency_provenance"][name]
            archive = absolute(dependency["installed_archive"])
            if archive not in actual or canonical.get(archive) != dependency["archive_sha256"]:
                raise ValueError(f"original {name} archive is not the declared actual link input")
            if canonical.get(str(Path(archive).with_suffix(".a"))) != dependency["static_archive_sha256"]:
                raise ValueError(f"conflicting {name} companion archive hash identity")

    def ordinary_dependency_files(self, name, dependency):
        archive = Path(dependency["installed_archive"])
        unit = dependency["original_unit"]
        cmx = archive.with_suffix(".cmx")
        if sha(cmx) != unit["cmx_sha256"]:
            raise ValueError(f"{name} original unit cmx hash differs")
        member = subprocess.check_output(["ar", "-p", str(archive.with_suffix(".a")), name + ".o"])
        if hashlib.sha256(member).hexdigest() != unit["object_sha256"]:
            raise ValueError(f"{name} original unit object hash differs")
        checkout = Path(dependency["source_checkout"])
        commit = dependency["pinned_commit"]
        if (not checkout.is_absolute() or not (checkout / ".git").exists()
                or self.run("git", "-C", checkout, "rev-parse", "HEAD") != commit
                or self.run("git", "-C", checkout, "status", "--porcelain", "--untracked-files=no")):
            raise ValueError(f"{name} source checkout differs from its pinned commit")
        sources = dependency["installed_sources_matched_to_pinned_git"]
        if not sources:
            raise ValueError(f"{name} installed source identity is missing")
        inputs = {str(cmx): unit["cmx_sha256"]}
        for filename, record in sources.items():
            git_path = record["git_path"]
            if any(Path(path).is_absolute() or ".." in Path(path).parts for path in (filename, git_path)):
                raise ValueError(f"{name} source path must stay within its recorded root")
            try:
                data = subprocess.check_output(["git", "-C", str(checkout), "show", commit + ":" + git_path],
                                               stderr=subprocess.PIPE)
            except subprocess.CalledProcessError as error:
                raise ValueError(f"{name} pinned source path is missing: {git_path}") from error
            if hashlib.sha256(data).hexdigest() != record["sha256"]:
                raise ValueError(f"{name} installed source hash differs from pinned Git bytes: {filename}")
            inputs[str(checkout / git_path)] = record["sha256"]
        return inputs

    def imported_native(self, source):
        """Read producer records as data; never execute their recorded commands."""
        envelope = json.loads(self.args.native_manifest.read_text())
        version = envelope.get("schema_version")
        if type(version) is not int or version not in (1, 2):
            raise ValueError("unsupported native manifest schema_version")
        self.native_schema_version = version
        directory = self.args.native_manifest.resolve().parent
        pre, link = [read_evidence(envelope[name], directory) for name in ("source", "link")]
        xmlm = read_evidence(envelope["xmlm_force_link"], directory) if version == 1 else None
        if version == 2 and "xmlm_force_link" in envelope:
            raise ValueError("ordinary-archive schema must not reinterpret a legacy XMLm force-link proof")
        if pre["lui"] != self.lui_sha:
            raise ValueError("producer LUI SHA differs from this checkout")
        # Build/tool/docs commits may advance HEAD; native bytes/configuration below must still match exactly.
        self.run("git", "merge-base", "--is-ancestor", pre["commit"], self.report["source_sha"])
        removed = self.run("git", "diff", "--name-only", "--diff-filter=D", pre["commit"], "--").splitlines()
        for name in sorted(set(source) | set(removed)):
            if (Path(name).name in {"dune", "dune-project", "dune-workspace"}
                    or name.endswith((".opam", ".opam.locked")) or name == ".agents/skills/journal-build/scripts/native_static_link_flags.sh"):
                original = subprocess.check_output(["git", "show", pre["commit"] + ":" + name], cwd=ROOT)
                if hashlib.sha256(original).hexdigest() != source.get(name):
                    raise ValueError(f"native build configuration changed since producer commit: {name}")
        lock = (ROOT / "logseq_journal.opam.locked").read_text()
        for key, package in (("signal", "ocaml-signal"), ("datascript", "datascript-ocaml-native")):
            expected = re.search(r'"' + package + r'\.[^"]+"\s*"git\+[^"#]+#([0-9a-f]{40})"', lock).group(1)
            if pre[key] != expected:
                raise ValueError(f"producer {package} differs from locked commit")
        native_sources = dict(pre["native_source_sha256"])
        for name, digest in link["device_c_source_sha256"].items():
            native_sources["logseq_sync/lib/effect_runner/platform/" + name] = digest
        required = {name: digest for name, digest in source.items()
                    if Path(name).suffix in {".ml", ".mli", ".c", ".h"}
                    and not {"tool", "test", "apple-tests"}.intersection(Path(name).parts)}
        mismatch = [name for name in sorted(set(required) | set(native_sources))
                    if native_sources.get(name) != required.get(name)]
        if mismatch:
            raise ValueError("producer native sources do not cover/match: " + ", ".join(mismatch))
        compiler = Path(link["command"][0])
        host = Path(pre["production_native_object"])
        if pre["production_native_object_sha256"] != link["production_host_sha256"]:
            raise ValueError("producer host object records disagree")
        self.native_include = compiler.parent.parent / "lib/ocaml"
        for name in ("mldoc", "xmlm"):
            expected = re.search(r'"' + name + r'\.dev"\s*"git\+[^"#]+#([0-9a-f]{40})"', lock).group(1)
            if link["new_dependency_provenance"][name]["pinned_commit"] != expected:
                raise ValueError(f"producer {name} differs from locked commit")
        if version == 2:
            self.ordinary_native_inputs(pre, link)
        if "validated_build" in envelope:
            inputs, historical = self.validated_native(envelope, directory, pre, link)
        else:
            inputs = self.producer_files(pre, link, xmlm, version=version)
            historical = {}
        additions = {str(host): link["production_host_sha256"],
                     str(self.args.native_manifest.resolve()): sha(self.args.native_manifest)}
        if version == 2:
            self.bind_native_inputs(inputs, additions)
        else:
            inputs.update(additions)
        for record in envelope.values():
            if isinstance(record, dict) and "path" in record:
                inputs[str((directory / record["path"]).resolve())] = record["sha256"]
        historical = {p: h for p, h in historical.items() if p not in inputs}
        for path, digest in inputs.items():
            if sha(path) != digest:
                raise ValueError(f"native input hash mismatch: {path}")
        self.verify_target(host, "MACOS")
        units = self.verify_ocaml_units(host, require_xmlm=version == 1)
        if version == 2 and "validated_build" in envelope and units != self.receipt_ocaml_units:
            raise ValueError("receipt unit retention differs from the fixed host object")
        symbols = self.run("nm", "-j", "-U", host)
        if any(name in symbols for name in ("_logseq_transport_dns_start", "_logseq_journal_crypto_call")):
            raise ValueError("host object still provides DNS/crypto; target C must provide them")
        self.host_object, self.native_files = host, inputs
        self.report["native_source_sha"] = pre["commit"]
        self.report["abi_limit"] = ("Host ARM64 producer only; no Apple App or iOS ABI validation"
            if getattr(self.args, "producer_only", False) else
            "EXPERIMENTAL: host ARM64 OCaml/runtime restamped; full iOS runtime ABI is not validated")
        print(self.report["abi_limit"], file=sys.stderr)
        return {"schema_version": version, "ocaml_units": units,
                "producer": envelope, "files": inputs, "historical_inputs": historical,
                "compiler_version": link["compiler_version"], "producer_command": link["command"],
                "source_sha": pre["commit"], "pins": {key: pre[key] for key in ("lui", "signal", "datascript")},
                "xmlm": ("single-unit force-link; original cmx/object bytes verified" if version == 1 else
                         "ordinary archive; original cmx/object bytes verified")}

    def validated_native(self, envelope, directory, pre, link):
        """Reuse a fixed complete object, with a hash-bound prior validation receipt."""
        receipt = read_evidence(envelope["validated_build"], directory)
        previous = receipt["inputs"]["dependencies"]
        version = envelope["schema_version"]
        if (receipt["status"] != "built" or receipt["mode"] != "experimental-host-restamp"
                or previous.get("source_sha", receipt["source_sha"]) != pre["commit"]
                or previous["compiler_version"] != link["compiler_version"]):
            raise ValueError("validated build receipt does not prove this producer object")
        if version == 1:
            if (not receipt["production_link"].get("runtime_mldoc_xmlm_retained")
                    or previous["xmlm"] != "single-unit force-link; original cmx/object bytes verified"):
                raise ValueError("legacy receipt does not prove runtime/mldoc/XMLm retention")
        else:
            units = previous.get("ocaml_units")
            if (previous.get("schema_version") != 2 or not self.valid_ocaml_units(units)
                    or receipt["production_link"].get("ocaml_units") != units
                    or "runtime_mldoc_xmlm_retained" in receipt["production_link"]
                    or previous.get("xmlm") != "ordinary archive; original cmx/object bytes verified"):
                raise ValueError("receipt does not prove ordinary-archive unit retention")
            self.receipt_ocaml_units = units
        evidence_names = ("source", "link", "xmlm_force_link") if version == 1 else ("source", "link")
        if previous["producer"].get("schema_version") != version:
            raise ValueError("receipt producer schema differs")
        for name in evidence_names:
            if previous["producer"][name] != envelope[name]:
                raise ValueError(f"validated build receipt producer evidence differs: {name}")
        verified = {**previous.get("historical_inputs", {}), **previous["files"]}
        expected = {} if version == 2 else dict(link["direct_native_input_sha256"])
        def add_expected(values):
            if version == 2:
                self.bind_native_inputs(expected, values)
            else:
                expected.update(values)
        if version == 2:
            add_expected(link["direct_native_input_sha256"])
        add_expected({pre["production_native_object"]: link["production_host_sha256"],
                      link["command"][0]: link["compiler_sha256"]})
        if version == 2:
            for name, dependency in link["new_dependency_provenance"].items():
                archive = Path(dependency["installed_archive"])
                add_expected({str(archive): dependency["archive_sha256"],
                    str(archive.with_suffix(".a")): dependency["static_archive_sha256"],
                    str(archive.with_suffix(".cmx")): dependency["original_unit"]["cmx_sha256"]})
                add_expected({str(archive.parent / filename): record["sha256"]
                    for filename, record in dependency["installed_sources_matched_to_pinned_git"].items()})
        for name in evidence_names:
            record = envelope[name]
            expected[str((directory / record["path"]).resolve())] = record["sha256"]
        if any(verified.get(path) != digest for path, digest in expected.items()):
            raise ValueError("validated build receipt native object/input hashes differ from producer")
        # These headers are still consumed by this build's fresh target C compilation.
        headers = {str(p): sha(p) for p in self.native_include.rglob("*.h")}
        recorded = {p: h for p, h in verified.items()
                    if p.endswith(".h") and self.native_include in Path(p).parents}
        if not recorded or headers != recorded:
            raise ValueError("current OCaml runtime headers differ from the validated producer ABI")
        self.report["producer_validation"] = {"receipt": envelope["validated_build"],
            "consumed_inputs": "historical hash proof only; old archive paths are not live build inputs"}
        return headers, verified

    def producer_files(self, pre, link, xmlm, *, version=1):
        """First import verifies still-present producer inputs and XMLm bytes in full."""
        inputs = {} if version == 2 else dict(link["direct_native_input_sha256"])
        def add(values):
            if version == 2:
                self.bind_native_inputs(inputs, values)
            else:
                inputs.update(values)
        if version == 2:
            add(link["direct_native_input_sha256"])
        compiler = Path(link["command"][0])
        if sha(compiler) != link["compiler_sha256"]:
            raise ValueError("producer compiler hash mismatch")
        add({str(compiler): link["compiler_sha256"]})
        add(pre["installed_lui_source_sha256"])
        for name in ("mldoc", "xmlm"):
            dependency = link["new_dependency_provenance"][name]
            archive = Path(dependency["installed_archive"])
            add({str(archive): dependency["archive_sha256"],
                 str(archive.with_suffix(".a")): dependency["static_archive_sha256"]})
            for filename, record in dependency["installed_sources_matched_to_pinned_git"].items():
                add({str(archive.parent / filename): record["sha256"]})
        if version == 2:
            for name in ("mldoc", "xmlm"):
                add(self.ordinary_dependency_files(name, link["new_dependency_provenance"][name]))
        else:
            add(self.forced_xmlm_files(compiler, link, xmlm))
        # The producer removed only host DNS/crypto from a local archive copy.
        command = self.ordinary_command if version == 2 else link["command"]
        effect = next(Path(p).parent for p in command if p.endswith("/logseq_sync_effect_runner_impl.cmxa"))
        for name in ("logseq_sync_effect_runner_impl.cmxa", "logseq_sync_effect_runner_impl.a"):
            original_path = next(p for p in inputs if Path(p).name == name)
            add({str(effect / name): inputs[original_path]})
        patched = effect / "liblogseq_sync_effect_runner_impl_stubs.a"
        add({str(patched): link["patched_host_stub_archive_sha256"]})
        if "platform_crypto_stubs.o" in self.run("ar", "-t", patched):
            raise ValueError("producer host DNS/crypto C member was not excluded")
        add({str(p): sha(p) for p in self.native_include.rglob("*.h")})
        if self.run(compiler, "-version") != link["compiler_version"]:
            raise ValueError("producer OCaml compiler version differs")
        return inputs

    def forced_xmlm_files(self, compiler, link, xmlm):
        # Legacy schema: only XMLm's original unit receives force-link metadata.
        command = xmlm["command"]
        if len(command) != 6 or command[:4] != [str(compiler), "-a", "-linkall", "-o"]:
            raise ValueError("XMLm proof must describe a single-unit -a -linkall archive")
        forced, cmx = Path(command[4]), Path(command[5])
        original = Path(link["new_dependency_provenance"]["xmlm"]["installed_archive"])
        if forced.name != "xmlm.cmxa" or cmx.name != "xmlm.cmx" or str(forced) not in link["command"]:
            raise ValueError("XMLm force-link archive was not a native link input")
        if sha(original.parent / "xmlm.cmx") != xmlm["original_cmx_sha256"] or sha(cmx) != xmlm["original_cmx_sha256"]:
            raise ValueError("XMLm original and force-linked cmx bytes differ")
        for archive in (original.with_suffix(".a"), forced.with_suffix(".a")):
            member = subprocess.check_output(["ar", "-p", str(archive), "xmlm.o"])
            if hashlib.sha256(member).hexdigest() != xmlm["original_object_sha256"]:
                raise ValueError("XMLm force-link changed original object bytes")
        info_tool = compiler.with_name("ocamlobjinfo")
        if "Force link: YES" not in self.run(info_tool, forced):
            raise ValueError("XMLm archive lacks force-link metadata")
        return {str(cmx): xmlm["original_cmx_sha256"], str(original.parent / "xmlm.cmx"): xmlm["original_cmx_sha256"],
                str(info_tool): sha(info_tool)}

    def preflight(self):
        a = self.args
        probe = getattr(a, "probe_native_object", None)
        if self.run("uname", "-m") != "arm64":
            raise RuntimeError("only Darwin arm64 is supported")
        sdk_name = {"macos": "macosx", "ios-simulator": "iphonesimulator", "ios-device": "iphoneos"}[a.platform]
        sdk = self.run("xcrun", "--sdk", sdk_name, "--show-sdk-path")
        triple = f"arm64-apple-{'macosx' if a.platform == 'macos' else 'ios'}{a.deployment_target}"
        if a.platform == "ios-simulator":
            triple += "-simulator"
        self.sdk, self.triple = sdk, triple
        # The existing Dune/icon helpers read these legacy variables. Bind them to this CLI's target.
        self.env.update(JOURNAL_APPLE_SDK_ROOT=sdk, JOURNAL_MACOS_DEPLOYMENT_TARGET=a.deployment_target,
                        JOURNAL_IOS_DEPLOYMENT_TARGET=a.deployment_target)
        self.swift_dir = Path(os.environ.get("JOURNAL_SWIFT_DIR", ROOT / "swift")).resolve()
        self.plist = Path(os.environ.get("JOURNAL_INFO_PLIST", ROOT / "apple/Info.plist")).resolve()
        self.entitlements = Path(os.environ.get("JOURNAL_ENTITLEMENTS_DIR", ROOT / "config/entitlements")).resolve()
        self.lui = Path(a.lui_package or os.environ.get("JOURNAL_LUI_PACKAGE_PATH", ROOT / "../lui/platform/apple")).resolve()
        if not (self.lui / "Package.swift").is_file():
            raise RuntimeError(f"LUI Apple package missing: {self.lui}; set --lui-package")
        # Production Swift LUI must agree with the OCaml lock; link-only may intentionally inspect another backend.
        lui_sha = self.lui_sha = self.run("git", "-C", self.lui, "rev-parse", "HEAD")
        if not (a.link_only or probe):
            expected = re.search(r'"git\+https://github.com/logseq/lui.git#([0-9a-f]{40})"',
                                 (ROOT / "logseq_journal.opam.locked").read_text()).group(1)
            if lui_sha != expected or self.run("git", "-C", self.lui, "status", "--porcelain", "--untracked-files=all"):
                raise RuntimeError(f"LUI Swift checkout must be clean at locked {expected}, found {lui_sha}")
        self.info = plistlib.loads(self.plist.read_bytes())
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"):
            if not self.info.get(key):
                raise RuntimeError(f"missing {key}: {self.plist}")
        if self.info["CFBundleExecutable"] != "JournalApp":
            raise RuntimeError("CFBundleExecutable must be JournalApp")
        if probe and (not self.info["CFBundleIdentifier"].endswith("-probe")
                      or any(path == ROOT or ROOT in path.parents for path in (self.swift_dir, self.plist))):
            raise RuntimeError("probe mode requires external staged Swift/plist and a distinct -probe bundle ID")
        if a.version:
            self.info["CFBundleShortVersionString"] = a.version
        if a.build_number:
            self.info["CFBundleVersion"] = a.build_number
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", self.info[key]):
                raise RuntimeError(f"invalid numeric {key}: {self.info[key]}")
        self.report["source_sha"] = self.run("git", "rev-parse", "HEAD")
        self.report["source_status"] = self.run("git", "status", "--porcelain")
        tools = {name: self.run("xcrun", "--sdk", sdk_name, "--find", name)
                 for name in ("swift", "clang", "actool")}
        toolchain = {"paths": tools, "hashes": {k: sha(v) for k, v in tools.items()},
                     "swift": self.run(tools["swift"], "--version"), "xcode": self.run("xcodebuild", "-version"),
                     "sdk": sdk, "sdk_version": self.run("xcrun", "--sdk", sdk_name, "--show-sdk-version"),
                     "path": self.env.get("PATH"), "developer_dir": self.env.get("DEVELOPER_DIR")}
        toolchain["sdk_identity"] = sdk_identity(sdk, sdk_name, toolchain["sdk_version"])
        self.tools = tools
        source = source_inputs()
        dependencies = {"mode": "stub; OCaml dependencies not used or validated"}
        if probe:
            probe = probe.resolve()
            self.verify_target(probe)
            symbols = self.run("nm", "-U", probe)
            if any(not re.search(r"\b_" + name + r"$", symbols, re.M)
                   for name in ("caml_startup", "lui_ocaml_start")):
                raise RuntimeError("probe object must define OCaml runtime and LUI bridge entry points")
            self.native_files = {str(probe): sha(probe)}
            dependencies = {"mode": "caller-supplied probe object; no production source or OCaml ABI proof",
                            "files": self.native_files, "production_source_validated": False}
        elif a.native_manifest:
            dependencies = self.imported_native(source)
        elif not a.link_only:
            toolchain.update(opam_identity(self.opam))
            self.prefix = Path(toolchain["opam_prefix"])
            dependencies = self.dependencies()
            if "architecture: arm64" not in toolchain["ocaml"] or "system: macosx" not in toolchain["ocaml"]:
                raise RuntimeError("macOS build requires native arm64 macosx OCaml compiler")
            toolchain["dune"] = self.opam("exec", "--", "dune", "--version")
            gmp = Path(self.run("pkg-config", "--variable=libdir", "gmp")) / "libgmp.a"
            toolchain["gmp"] = {"path": str(gmp), "sha256": sha(gmp)}
        signing = self.device_signing() if a.platform == "ios-device" else {}
        self.inputs = {"source": source, "swift": files(self.swift_dir), "lui": files(self.lui),
                       "lui_sha": lui_sha, "plist": sha(self.plist), "entitlements": files(self.entitlements),
                       "dependencies": dependencies, "toolchain": toolchain, "target": triple,
                       "signing": signing, "flags": {"configuration": a.configuration,
                                 "mode": "native" if getattr(a, "producer_only", False) else self.report["mode"],
                                 "info": self.info, "sign_identity": a.sign_identity}}
        self.inputs["flags"]["teams"] = {name: self.env.get(name) for name in ("JOURNAL_IOS_TEAM_ID", "JOURNAL_MACOS_TEAM_ID")}
        self.report.update(inputs=self.inputs, target=triple, sdk_name=sdk_name, architecture="arm64",
                           cache_key=fingerprint(self.inputs))
        self.save()

    def native_link_rule(self, workspace):
        """Read the current rule even when Dune's incremental build ran no linker."""
        rules = json.loads(self.opam("exec", "--", "dune", "rules", "--root", ROOT, "--no-config",
            "--cache=disabled", "--build-dir", workspace / "dune", "--profile",
            "dev" if self.args.configuration == "debug" else "release", "--format=json", "app/native_embed.exe.o"))
        if len(rules) != 1:
            raise ValueError("producer needs exactly one native Dune link rule")
        action, cwd = rules[0]["action"], ROOT
        while isinstance(action, list) and len(action) == 3 and action[0] == "chdir":
            cwd = Path(os.path.abspath(cwd / action[1]))
            action = action[2]
        if (not isinstance(action, list) or len(action) < 2 or action[0] != "run"
                or not all(isinstance(arg, str) for arg in action[1:])
                or cwd != workspace / "dune/default"):
            raise ValueError("unsupported native Dune action; expected one complete-object compiler command")
        command = action[1:]
        command[0] = os.path.abspath(cwd / command[0])
        compiler = self.prefix / "bin/ocamlopt.opt"
        if command[0] != str(compiler) or sha(compiler) != self.inputs["toolchain"]["compiler_sha256"]:
            raise ValueError("Dune producer compiler identity differs from preflight")
        return cwd, command

    def producer_pin(self, name):
        pins = [pin for package, pin in self.inputs["dependencies"]["pins"].items()
                if package.split(".", 1)[0] == name]
        if len(pins) != 1:
            raise ValueError(f"producer needs one resolved {name} pin")
        return pins[0]

    def producer_dependency(self, name, archive):
        pin = self.producer_pin(name)
        checkout, commit = Path(pin["checkout"]), pin["resolved_sha"]
        tracked = self.run("git", "-C", checkout, "ls-files", "-z").split("\0")
        originals = {}
        for path in tracked:
            if Path(path).suffix in {".ml", ".mli"}:
                blob = subprocess.check_output(["git", "-C", str(checkout), "show", commit + ":" + path])
                originals.setdefault((Path(path).name, hashlib.sha256(blob).hexdigest()), []).append(path)
        sources = {}
        for path in sorted(archive.parent.iterdir()):
            if path.suffix in {".ml", ".mli"}:
                digest = sha(path)
                matches = originals.get((path.name, digest), [])
                if len(matches) == 1:
                    sources[path.name] = {"sha256": digest, "git_path": matches[0]}
        if name + ".ml" not in sources:
            raise ValueError(f"{name} installed source does not match its pinned Git bytes")
        member = subprocess.check_output(["ar", "-p", str(archive.with_suffix(".a")), name + ".o"])
        return {"pinned_commit": commit, "source_checkout": str(checkout), "installed_archive": str(archive),
                "archive_sha256": sha(archive), "static_archive_sha256": sha(archive.with_suffix(".a")),
                "installed_sources_matched_to_pinned_git": sources,
                "original_unit": {"cmx_sha256": sha(archive.with_suffix(".cmx")),
                                  "object_sha256": hashlib.sha256(member).hexdigest()}}

    def produce_native(self, native, workspace):
        """Produce immutable schema-2 evidence, without claiming a built Apple App."""
        self.phase = "producer-prepare"
        if sha(native) != self.report["native_object"]["sha256"]:
            raise ValueError("original native object hash changed before production")
        self.verify_target(native, "MACOS")
        cwd, original = self.native_link_rule(workspace)
        directory = workspace / "native-producer"
        envelope_path = directory / "native-input.json"
        rule = {"working_directory": str(cwd), "command": original,
                "original_object": {"path": str(native), "sha256": sha(native)}}
        reused = directory.exists()
        if reused:
            if not envelope_path.is_file() or json.loads((directory / "dune-rule.json").read_text()) != rule:
                raise ValueError("producer cache rule/object identity changed or is incomplete; choose a fresh cache")
        else:
            directory.mkdir()
            def dump(name, value):
                path = directory / name
                with path.open("x") as stream:
                    stream.write(json.dumps(value, indent=2) + "\n")
                return {"path": str(path), "sha256": sha(path)}
            def absolute(arg):
                return Path(os.path.abspath(cwd / arg))
            effects = [absolute(arg) for arg in original if arg.endswith("/logseq_sync_effect_runner_impl.cmxa")]
            if len(effects) != 1:
                raise ValueError("producer needs one original effect-runner archive")
            effect = effects[0].parent
            copied = directory / "host-stubs"
            copied.mkdir()
            inputs = {}
            def record(path):
                path = absolute(path)
                self.bind_native_inputs(inputs, {str(path): sha(path)})
            for name in ("logseq_sync_effect_runner_impl.cmxa", "logseq_sync_effect_runner_impl.a"):
                record(effect / name)
                shutil.copyfile(effect / name, copied / name)
            stub_name = "liblogseq_sync_effect_runner_impl_stubs.a"
            patched = copied / stub_name
            shutil.copyfile(effect / stub_name, patched)
            if self.run("ar", "-t", patched).splitlines().count("platform_crypto_stubs.o") != 1:
                raise ValueError("producer needs exactly one original host DNS/crypto C member")
            self.run("ar", "-d", patched, "platform_crypto_stubs.o", env=dict(self.env, ZERO_AR_DATE="1"))
            if "platform_crypto_stubs.o" in self.run("ar", "-t", patched).splitlines():
                raise ValueError("host DNS/crypto member was not removed from the owned archive copy")
            command, includes = [original[0]], []
            for index, arg in enumerate(original[1:], 1):
                previous = original[index - 1]
                if previous == "-o":
                    arg = str(directory / "production-host.o")
                elif previous == "-I":
                    path = absolute(arg)
                    arg = str(copied if path == effect else path)
                    includes.append(Path(arg))
                elif previous == "-cclib" and arg.startswith("-L") and len(arg) > 2:
                    arg = "-L" + str(absolute(arg[2:]))
                elif previous not in {"-w", "-warn-error"} and not arg.startswith("-") and Path(arg).suffix in {".cmxa", ".cmx", ".a", ".o"}:
                    path = absolute(arg)
                    path = copied / path.name if path == effects[0] else path
                    arg = str(path)
                    record(path)
                    if path.suffix in {".cmxa", ".cmx"}:
                        record(path.with_suffix(".a" if path.suffix == ".cmxa" else ".o"))
                command.append(arg)
            runtime = Path(self.run(original[0], "-where"))
            if runtime.resolve() != (self.prefix / "lib/ocaml").resolve():
                raise ValueError("producer compiler runtime differs from the selected switch")
            # These include-search candidates bind implicit C/runtime providers as well as explicit inputs.
            for include in includes + [runtime]:
                for archive in sorted(include.glob("*.a")):
                    record(archive)
            # Bind headers now: the first target import must reject later header changes,
            # rather than adopting whatever bytes happen to be installed at handoff.
            headers = list((self.prefix / "lib/ocaml").rglob("*.h"))
            if not headers:
                raise ValueError("producer OCaml runtime headers are missing")
            for header in headers:
                record(header)
            dependencies = {}
            for name in ("mldoc", "xmlm"):
                archives = [Path(arg) for arg in command if Path(arg).name == name + ".cmxa"]
                if len(archives) != 1:
                    raise ValueError(f"producer needs one original {name} archive in the actual link command")
                dependencies[name] = self.producer_dependency(name, archives[0])
            pre = {"commit": self.report["source_sha"], "lui": self.lui_sha,
                "signal": self.producer_pin("ocaml-signal")["resolved_sha"],
                "datascript": self.producer_pin("datascript-ocaml-native")["resolved_sha"],
                "native_source_sha256": {name: digest for name, digest in self.inputs["source"].items()
                    if Path(name).suffix in {".ml", ".mli", ".c", ".h"}
                    and not {"tool", "test", "apple-tests"}.intersection(Path(name).parts)},
                "installed_lui_source_sha256": {str(p): sha(p) for p in (self.prefix / "lib/lui").rglob("*")
                    if p.is_file() and p.suffix in {".ml", ".mli"}},
                "production_native_object": str(directory / "production-host.o")}
            link = {"command": command, "working_directory": str(cwd), "direct_native_input_sha256": inputs,
                "compiler_sha256": self.inputs["toolchain"]["compiler_sha256"],
                "compiler_version": self.run(original[0], "-version"), "new_dependency_provenance": dependencies,
                "patched_host_stub_archive_sha256": sha(patched),
                "device_c_source_sha256": {p.name: sha(p) for p in
                    (ROOT / "logseq_sync/lib/effect_runner/platform").glob("platform_crypto_stubs.*")}}
            # Reject unbound/unknown command forms before executing the current Dune-derived relink.
            self.ordinary_native_inputs(pre, link)
            link["command"] = self.ordinary_command
            self.phase = "producer-link"
            self.run(*link["command"], cwd=cwd)
            if any(sha(path) != digest for path, digest in inputs.items()):
                raise ValueError("native link input hash changed during production")
            pre["production_native_object_sha256"] = link["production_host_sha256"] = sha(pre["production_native_object"])
            envelope = {"schema_version": 2, "source": dump("source.json", pre), "link": dump("link.json", link),
                        "dune_rule": dump("dune-rule.json", rule)}
            dump("native-input.json", envelope)
        self.phase = "verify-producer"
        previous = self.args.native_manifest
        try:
            self.args.native_manifest = envelope_path
            imported = self.imported_native(self.inputs["source"])
        finally:
            self.args.native_manifest = previous
        self.native_files[str(native)] = rule["original_object"]["sha256"]
        self.report["producer"] = {"envelope": {"path": str(envelope_path), "sha256": sha(envelope_path)},
            "object": {"path": str(self.host_object), "sha256": sha(self.host_object)},
            "ocaml_units": imported["ocaml_units"], "link_executed": not reused}
        return envelope_path

    def compile(self, workspace):
        a = self.args
        self.phase = "native"
        native_units = None
        if a.link_only:
            source = workspace / "ocaml_stub.c"
            source.write_text(STUB)
            native = workspace / "journal_stub.o"
            self.run(self.tools["clang"], "-target", self.triple, "-isysroot", self.sdk,
                     "-fPIC", "-c", source, "-o", native)
        elif a.probe_native_object:
            native = a.probe_native_object.resolve()
        elif a.native_manifest:
            native = workspace / "journal_complete_restamped.o"
            platform = "2" if a.platform == "ios-device" else "7"
            self.run("xcrun", "vtool", "-set-build-version", platform, a.deployment_target,
                     self.inputs["toolchain"]["sdk_version"], "-replace", "-output", native, self.host_object)
            self.target_c = workspace / "platform_crypto.o"
            self.run(self.tools["clang"], "-target", self.triple, "-isysroot", self.sdk,
                     "-O2", "-fno-strict-aliasing", "-fwrapv", "-pthread", "-D_FILE_OFFSET_BITS=64", "-Wall", "-g",
                     "-I", self.native_include, "-c", ROOT / "logseq_sync/lib/effect_runner/platform/platform_crypto_stubs.c",
                     "-o", self.target_c)
            self.verify_target(self.target_c)
        else:
            dune_dir = workspace / "dune"
            self.env.update(DUNE_CACHE_ROOT=str(workspace / "dune-cache"),
                            XDG_CACHE_HOME=str(workspace / "xdg-cache"))
            self.opam("exec", "--", "dune", "build", "--root", ROOT, "--no-config", "--cache=disabled",
                      "--build-dir", dune_dir, "--trace-file", self.run_dir / "native-trace.json",
                      "--profile", "dev" if a.configuration == "debug" else "release",
                      "-j", str(a.jobs), "app/native_embed.exe.o")
            native = dune_dir / "default/app/native_embed.exe.o"
            self.native_gmp = dune_dir / "default/app/libgmp.a"
            self.report["linked_gmp"] = {"path": str(self.native_gmp), "sha256": sha(self.native_gmp)}
            native_units = self.verify_ocaml_units(native, require_xmlm=False)
        self.report["native_object"] = {"path": str(native), "sha256": sha(native), "mode": self.report["mode"]}
        if native_units is not None:
            self.report["native_object"]["ocaml_units"] = native_units
        if getattr(a, "producer_only", False):
            return self.produce_native(native, workspace)
        self.phase = "swift"
        scratch = workspace / "swift"
        native_inputs = [native, self.target_c] if a.native_manifest else [native]
        self.env.update(JOURNAL_LUI_PACKAGE_PATH=str(self.lui), JOURNAL_NATIVE_LINK_INPUTS=":".join(map(str, native_inputs)),
                        CLANG_MODULE_CACHE_PATH=str(workspace / "clang-modules"),
                        SWIFTPM_MODULECACHE_OVERRIDE=str(workspace / "swift-modules"))
        argv = [self.tools["swift"], "build", "--package-path", self.swift_dir, "--scratch-path", scratch,
                "--cache-path", workspace / "swift-cache", "--config-path", workspace / "swift-config",
                "--security-path", workspace / "swift-security", "--product", "JournalApp",
                "--configuration", a.configuration, "--triple", self.triple, "--sdk", self.sdk,
                "--skip-update", "--disable-automatic-resolution", "--disable-index-store", "-j", str(a.jobs),
                "-Xlinker", "-syslibroot", "-Xlinker", self.sdk]
        if a.platform == "ios-simulator":
            ent = plistlib.loads((self.entitlements / "ios-debug-profile.entitlements").read_bytes())
            bundle = self.info["CFBundleIdentifier"]
            team = os.environ.get("JOURNAL_IOS_TEAM_ID", "K378MFWK59")
            ent.update({"keychain-access-groups": [f"{team}.{bundle}"], "application-identifier": f"{team}.{bundle}"})
            ent_path = workspace / "sim-entitlements.plist"
            ent_path.write_bytes(plistlib.dumps(ent))
            argv += ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
                     "-Xlinker", ent_path]
        if a.native_manifest:
            self.link_map = workspace / "native-link-map.txt"
            argv += ["-Xlinker", "-map", "-Xlinker", self.link_map]
        self.run(*argv)
        # Query the same product/configuration; never fall back to another platform's .build/debug.
        product = Path(self.run(*argv, "--show-bin-path").splitlines()[-1]) / "JournalApp"
        self.verify_target(product)
        if a.native_manifest:
            self.verify_production_link(product)
        return product

    def verify_target(self, product, platform=None):
        if self.run("xcrun", "lipo", "-archs", product) != "arm64":
            raise RuntimeError(f"wrong binary architecture: {product}")
        output = self.run("xcrun", "vtool", "-show-build", product)
        platform = platform or {"macos": "MACOS", "ios-simulator": "IOSSIMULATOR", "ios-device": "IOS"}[self.args.platform]
        if not re.search(r"platform\s+" + platform + r"\b", output):
            raise RuntimeError(f"wrong Mach-O platform, expected {platform}: {product}")

    def verify_production_link(self, product):
        version = self.native_schema_version
        units = self.verify_ocaml_units(product, require_xmlm=version == 1)
        text = self.link_map.read_text()
        objects = {int(m[1]): m[2].strip() for line in text.splitlines()
                   if (m := re.match(r"^\[\s*(\d+)\]\s+(.+)$", line))}
        for symbol in ("_logseq_transport_dns_start", "_logseq_journal_crypto_call"):
            rows = [line for line in text.splitlines() if line.split() and line.split()[-1] == symbol]
            match = re.search(r"\[\s*(\d+)\]", rows[0]) if len(rows) == 1 else None
            if not match or objects[int(match[1])] != str(self.target_c):
                raise ValueError(f"final {symbol} provider is not the freshly compiled target C object")
        swift_objects = {}
        for line in (product.parent / "JournalApp.product/Objects.LinkFileList").read_text().splitlines():
            obj = Path(shlex.split(line)[0])
            self.verify_target(obj)
            swift_objects[str(obj)] = sha(obj)
        dylibs = self.run("otool", "-L", product).splitlines()[1:]
        if any(not line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in dylibs):
            raise ValueError("product links a non-system dynamic library")
        self.report["production_link"] = {"link_map": str(self.link_map), "link_map_sha256": sha(self.link_map),
            "target_c": {"path": str(self.target_c), "sha256": sha(self.target_c)}, "swift_objects": swift_objects,
            "ocaml_units": units, "cross_abi_validated": False}
        if version == 1:
            self.report["production_link"]["runtime_mldoc_xmlm_retained"] = True

    def device_signing(self):
        a = self.args
        profile = plistlib.loads(self.run("security", "cms", "-D", "-i", a.provisioning_profile).encode())
        if "iOS" not in profile.get("Platform", []):
            raise ValueError("provisioning profile is not for iOS")
        if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
            raise ValueError("provisioning profile expired")
        certificate = a.sign_identity.upper()
        if certificate not in {hashlib.sha1(c).hexdigest().upper() for c in profile["DeveloperCertificates"]}:
            raise ValueError("signing certificate is not in the provisioning profile")
        if certificate not in self.run("security", "find-identity", "-v", "-p", "codesigning"):
            raise ValueError("requested signing identity is unavailable")
        self.device_entitlements = plistlib.loads(a.sign_entitlements.read_bytes())
        self.team = profile["TeamIdentifier"][0]
        if self.device_entitlements.get("application-identifier") != f"{self.team}.{self.info['CFBundleIdentifier']}":
            raise ValueError("device entitlement application-identifier does not match team/bundle")
        def allowed(requested, grant):
            if isinstance(requested, list):
                return isinstance(grant, list) and all(any(allowed(x, y) for y in grant) for x in requested)
            if isinstance(requested, str) and isinstance(grant, str):
                return fnmatch.fnmatchcase(requested, grant)
            return requested == grant
        grants = profile["Entitlements"]
        if any(key not in grants or not allowed(value, grants[key]) for key, value in self.device_entitlements.items()):
            raise ValueError("requested device entitlements exceed provisioning profile")
        self.report["device_signing"] = {"team": self.team, "certificate": certificate, "profile_uuid": profile["UUID"],
                                       "expires": profile["ExpirationDate"].isoformat()}
        return {str(p.resolve()): sha(p) for p in (a.provisioning_profile, a.sign_entitlements)}

    def assemble(self, product, app):
        self.phase = "package"
        # mkdir is exclusive: no existing output, rollback app or arbitrary directory is removed.
        app.mkdir(parents=True, exist_ok=False)
        mac = self.args.platform == "macos"
        resource = app / "Contents/Resources" if mac else app
        executable = app / "Contents/MacOS/JournalApp" if mac else app / "JournalApp"
        plist = app / "Contents/Info.plist" if mac else app / "Info.plist"
        resource.mkdir(parents=True, exist_ok=True)
        executable.parent.mkdir(parents=True, exist_ok=True)
        info = plistlib.loads(plistlib.dumps(self.info))
        info.update(JournalSourceRevision=self.report["source_sha"],
                    JournalBuildInputDigest=self.report["cache_key"], JournalBuildMode=self.report["mode"])
        if self.args.experimental_host_restamp:
            info.update(JournalOCamlRuntimeOrigin="host-arm64-restamp", JournalCrossABIValidated=False)
        if self.report["mode"] == "probe-object":
            info.update(JournalOCamlRuntimeOrigin="caller-supplied-probe", JournalCrossABIValidated=False,
                        JournalProductionSourceValidated=False)
        info["LSMinimumSystemVersion" if mac else "MinimumOSVersion"] = self.args.deployment_target
        info.setdefault("CFBundleURLTypes", []).append({"CFBundleURLName": "com.logseq.journal.auth",
                                                       "CFBundleURLSchemes": ["logseqjournal"]})
        plist.write_bytes(plistlib.dumps(info))
        shutil.copy2(product, executable)
        # SwiftPM resource bundles must travel with the executable.
        for bundle in product.parent.glob("*.bundle"):
            shutil.copytree(bundle, resource / bundle.name)
        self.run("bash", ROOT / ".agents/skills/journal-build/scripts/package_journal_apple_icons.sh", self.args.platform, app)
        if not (resource / "Assets.car").is_file():
            raise RuntimeError("icon Assets.car missing")
        packaged = plistlib.loads(plist.read_bytes())
        if not mac and (packaged.get("UIDeviceFamily") != [1]
                        or packaged.get("ITSAppUsesNonExemptEncryption") is not False):
            raise RuntimeError("Journal iOS packaging requires iPhone-only family and the reviewed encryption declaration")
        if not any(key in packaged for key in ("CFBundleIconName", "CFBundleIcons")):
            raise RuntimeError("packaged icon declaration missing")
        self.phase = "sign"
        command = ["codesign", "--force", "--sign", self.args.sign_identity, "--timestamp=none"]
        team = None
        if mac:
            ent = plistlib.loads((self.entitlements / "macos-debug-profile.entitlements").read_bytes())
            # Local adhoc signing; a team identity requires the explicit team id.
            ent.pop("application-identifier", None)
            team = os.environ.get("JOURNAL_MACOS_TEAM_ID")
            if self.args.sign_identity != "-":
                if not team:
                    raise RuntimeError("JOURNAL_MACOS_TEAM_ID required for a development identity")
                ent["keychain-access-groups"] = [f"{team}.{info['CFBundleIdentifier']}"]
            else:
                ent.pop("keychain-access-groups", None)
            ent_path = self.run_dir / "sign-entitlements.plist"
            ent_path.write_bytes(plistlib.dumps(ent))
            command += ["--entitlements", ent_path]
        elif self.args.platform == "ios-device":
            team = self.team
            shutil.copy2(self.args.provisioning_profile, app / "embedded.mobileprovision")
            command += ["--entitlements", self.args.sign_entitlements, "--generate-entitlement-der"]
        self.run(*command, app)
        self.run("codesign", "--verify", "--deep", "--strict", app)
        signature = self.run("codesign", "-d", "--verbose=4", app)
        if team and f"TeamIdentifier={team}" not in signature:
            raise RuntimeError("signature team differs from requested team")
        if self.args.platform == "ios-device":
            output = self.run("codesign", "-d", "--entitlements", ":-", app)
            signed = plistlib.loads(output[output.index("<?xml"):output.index("</plist>") + 8].encode())
            if signed != self.device_entitlements:
                raise ValueError("signed entitlements differ from the requested device entitlements")
        self.verify_target(executable)
        self.report["artifact"] = {"app": str(app), "info": packaged, "files": files(app), "signature": signature,
                                   "executable_sha256": sha(executable), "sign_identity": self.args.sign_identity}

    def verify_inputs(self):
        self.phase = "verify-inputs"
        if (source_inputs() != self.inputs["source"] or files(self.swift_dir) != self.inputs["swift"]
                or files(self.lui) != self.inputs["lui"] or sha(self.plist) != self.inputs["plist"]
                or files(self.entitlements) != self.inputs["entitlements"]):
            raise RuntimeError("source changed during build; artifact is not accepted, rerun with stable inputs")
        if any(sha(path) != self.inputs["toolchain"]["hashes"][name] for name, path in self.tools.items()):
            raise RuntimeError("Apple toolchain changed during build; artifact is not accepted")
        if any(sha(p) != h for p, h in self.inputs["toolchain"]["sdk_identity"]["settings"].items()):
            raise RuntimeError("SDK identity changed during build; artifact is not accepted")
        gmp = self.inputs["toolchain"].get("gmp")
        if gmp and (sha(gmp["path"]) != gmp["sha256"]
                    or sha(getattr(self, "native_gmp", gmp["path"])) != gmp["sha256"]):
            raise RuntimeError("GMP archive changed during build; artifact is not accepted")
        imported = getattr(self, "native_files", {})
        if any(sha(p) != h for p, h in {**imported, **self.inputs["signing"]}.items()):
            raise RuntimeError("imported native/signing inputs changed during build; artifact is not accepted")
        a = self.args
        if not (a.link_only or a.native_manifest or getattr(a, "probe_native_object", None)):
            if getattr(a, "producer_only", False):
                current = opam_identity(self.opam)
                if any(self.inputs["toolchain"].get(name) != value for name, value in current.items()):
                    raise RuntimeError("OCaml compiler changed during build; producer is not accepted")
            if self.dependencies() != self.inputs["dependencies"]:
                raise RuntimeError("switch changed during build; artifact is not accepted")


def arguments():
    parser = argparse.ArgumentParser(description="Build Journal Apple host; never installs or updates dependencies.")
    parser.add_argument("platform", choices=("macos", "ios-simulator", "ios-device"), nargs="?", default="macos")
    parser.add_argument("app_directory", nargs="?", help="legacy positional output path; must not exist")
    parser.add_argument("--app-dir", type=Path)
    parser.add_argument("--switch", help="explicit pre-provisioned opam switch (native macOS only)")
    parser.add_argument("--lui-package", type=Path, help="local LUI platform/apple package")
    parser.add_argument("--preflight", action="store_true", help="check inputs without compiling")
    parser.add_argument("--producer-only", action="store_true", help="native macOS producer evidence only; no Swift, App packaging or signing")
    parser.add_argument("--link-only", action="store_true", help="explicit stub build; not runnable acceptance")
    parser.add_argument("--experimental-host-restamp", action="store_true", help="explicit existing host ARM64 compatibility route; full iOS ABI unverified")
    parser.add_argument("--native-manifest", type=Path, help="hash-verified source/link/XMLm producer evidence envelope")
    parser.add_argument("--probe-native-object", type=Path, help="isolated macOS/Simulator probe only; target-checked object, no production source/ABI proof")
    parser.add_argument("--cache-dir", type=Path, default=Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "logseq-journal-build")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--deployment-target", default="26.0")
    parser.add_argument("--version")
    parser.add_argument("--build-number")
    parser.add_argument("--sign-identity", default="-", help="macOS identity; default adhoc, Simulator always adhoc")
    parser.add_argument("--provisioning-profile", type=Path, help="existing device profile; never downloaded")
    parser.add_argument("--sign-entitlements", type=Path, help="existing device signing entitlements")
    a = parser.parse_args()
    if a.producer_only and (a.platform != "macos" or a.link_only or a.native_manifest or a.experimental_host_restamp
                           or a.probe_native_object or a.app_dir or a.app_directory or a.sign_identity != "-"
                           or a.provisioning_profile or a.sign_entitlements):
        parser.error("producer-only requires native macOS --switch inputs without App output/import/signing modes")
    if a.probe_native_object and (a.platform == "ios-device" or a.switch or a.link_only or a.native_manifest or a.experimental_host_restamp):
        parser.error("probe mode is isolated macOS/Simulator object import, separate from production/stub modes")
    for name in ("JOURNAL_OCAML_OBJECT", "JOURNAL_EXTRA_OBJECTS", "JOURNAL_NATIVE_LINK_INPUTS"):
        if os.environ.get(name):
            parser.error(f"{name} is unproven input; use native macOS --switch or explicit --link-only. "
                         "Probe helpers use isolated --probe-native-object; host restamp is not cross compilation.")
    if bool(a.native_manifest) != a.experimental_host_restamp:
        parser.error("--native-manifest and --experimental-host-restamp must be supplied together")
    if a.experimental_host_restamp and (a.link_only or a.switch or a.platform == "macos"):
        parser.error("experimental import is an iOS mode, separate from --link-only and --switch")
    if a.platform == "ios-device" and not a.experimental_host_restamp:
        parser.error("iPhone build blocked: no verified complete OCaml iOS cross toolchain/ABI route; host restamp is unsupported")
    if a.platform == "ios-simulator" and not (a.link_only or a.experimental_host_restamp or a.probe_native_object):
        parser.error("Simulator runtime build blocked; use --link-only for Swift/link checks. Host restamp is not verified cross compilation.")
    if not (a.link_only or a.native_manifest or a.probe_native_object or a.switch):
        parser.error("native macOS requires --switch; no implicit switch/pin changes")
    if a.platform == "ios-simulator" and a.sign_identity != "-":
        parser.error("Simulator requires adhoc signature; entitlements live in __TEXT")
    if a.platform == "ios-device" and (not a.provisioning_profile or not a.sign_entitlements or not re.fullmatch(r"[0-9A-Fa-f]{40}", a.sign_identity)):
        parser.error("device build requires --provisioning-profile, --sign-entitlements and certificate SHA1 --sign-identity")
    a.app_dir = a.app_dir or (Path(a.app_directory) if a.app_directory else None)
    if a.app_dir and a.app_dir.exists():
        parser.error(f"output exists; preserve it and choose a new path: {a.app_dir}")
    if a.jobs < 1 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", a.deployment_target) or int(a.deployment_target.split(".")[0]) < 26:
        parser.error("jobs must be positive and deployment-target must be numeric >= 26.0 (Swift package minimum)")
    # Ambient compiler and lookup overrides invalidate the declared switch/SDK identity.
    for name in ("OCAMLPATH", "OCAMLLIB", "OCAMLPARAM", "OCAMLFIND_CONF", "OCAMLFIND_TOOLCHAIN", "DUNE_PROFILE",
                 "DUNE_ROOT", "DUNE_WORKSPACE", "DUNE_CROSS_TARGET", "DUNE_INSTRUMENT_WITH", "DUNE_TARGET_EXEC",
                 "OCAMLFIND_COMMANDS", "OCAMLFIND_LDCONF", "CAML_LD_LIBRARY_PATH", "MACOSX_DEPLOYMENT_TARGET",
                 "IPHONEOS_DEPLOYMENT_TARGET", "ARCHFLAGS", "CFLAGS", "CPPFLAGS", "LDFLAGS", "CC", "CXX", "LD", "AR",
                 "SWIFT_EXEC", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR"):
        if os.environ.get(name):
            parser.error(f"unset ambient {name}; this entry point selects explicit tools/SDK and switch")
    a.cache_dir = a.cache_dir.expanduser().resolve()
    if a.cache_dir == ROOT or ROOT in a.cache_dir.parents:
        parser.error("--cache-dir must be outside the repository")
    return a


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    a = arguments()
    a.cache_dir.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        stack.enter_context(resource_lock(a.cache_dir / "build.lock"))
        run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=a.cache_dir))
        build = Build(a, run_dir)
        try:
            if not (a.link_only or a.native_manifest or a.probe_native_object):
                prefix = Path(build.opam("var", "prefix"))
                # opam uses POSIX record locks. Keep its switch read-locked for the whole build.
                switch_lock = stack.enter_context((prefix / ".opam-switch/lock").open("rb"))
                try:
                    fcntl.lockf(switch_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise RuntimeError(f"busy: opam switch is being modified: {prefix}") from None
            build.preflight()
            if not a.preflight:
                workspace = a.cache_dir / "objects" / build.report["cache_key"]
                workspace.mkdir(parents=True, exist_ok=True)
                build.report["cache_reused"] = (workspace / "inputs.json").exists()
                (workspace / "inputs.json").write_text(json.dumps(build.inputs, indent=2) + "\n")
                product = build.compile(workspace)
                if not a.producer_only:
                    build.assemble(product, a.app_dir or run_dir / "LogseqJournal.app")
                build.verify_inputs()
            build.report["status"] = "preflight-passed" if a.preflight else "native-produced" if a.producer_only else "built"
            build.report["finished"] = datetime.now(timezone.utc).isoformat()
            build.save()
            print(build.report.get("artifact", {}).get("app", "preflight passed") if a.preflight or not a.producer_only else product)
            print(f"manifest: {run_dir / 'manifest.json'}", file=sys.stderr)
        except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            build.report.update(status="failed", failed_phase=build.phase, error=str(error))
            build.save()
            print(f"build failed [{build.phase}]: {error}\nmanifest: {run_dir / 'manifest.json'}", file=sys.stderr)
            return 1
    return 0


STUB = """// Link-validation stub matching app/journal_lui_bridge.c's exported entries.
// Explicit --link-only mode; never runtime acceptance.
#include <stdint.h>
typedef void (*patch_cb)(const char *);
typedef void (*wakeup_cb)(void);
typedef void (*platform_request_cb)(const char *, int32_t);
int32_t lui_ocaml_start(patch_cb cb, int32_t p, int32_t h, const char *d, int32_t l)
  { (void)p; (void)h; (void)d; (void)l; if (cb) cb(""); return 1; }
int32_t lui_ocaml_stop(void) { return 1; }
int32_t lui_ocaml_appear(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_long_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_text_changed(int64_t n, const char *t) { (void)n; (void)t; return 1; }
int32_t lui_ocaml_submit(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_dismiss(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_double_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_toggle_changed(int64_t n, int32_t c) { (void)n; (void)c; return 1; }
int32_t lui_ocaml_radio_changed(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_slider_changed(int64_t n, double v) { (void)n; (void)v; return 1; }
int32_t lui_ocaml_press_detail(int64_t n, double x, double y, int32_t m, int32_t b, const char *t)
  { (void)n; (void)x; (void)y; (void)m; (void)b; (void)t; return 1; }
int32_t lui_ocaml_pointer_down(int64_t n, double x, double y, int32_t m, int32_t b, const char *t)
  { return lui_ocaml_press_detail(n, x, y, m, b, t); }
int32_t lui_ocaml_pointer_up(int64_t n, double x, double y, int32_t m, int32_t b, const char *t)
  { return lui_ocaml_press_detail(n, x, y, m, b, t); }
int32_t lui_ocaml_context_menu_press(int64_t n, double x, double y, int32_t m, int32_t b, const char *t)
  { return lui_ocaml_press_detail(n, x, y, m, b, t); }
int32_t lui_ocaml_pointer_enter(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_pointer_leave(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_scroll_completed(int64_t n, int64_t token, const char *outcome)
  { (void)n; (void)token; (void)outcome; return 1; }
int32_t lui_ocaml_visible_range(int64_t n, int64_t first, int64_t last)
  { (void)n; (void)first; (void)last; return 1; }
int32_t lui_ocaml_picked(int64_t n, const char *payload) { (void)n; (void)payload; return 1; }
int32_t journal_ocaml_extension_event(int64_t n, const char *name, const char *p)
  { (void)n; (void)name; (void)p; return 1; }
int32_t journal_ocaml_pump(void) { return 1; }
void journal_ocaml_platform_event(const char *d, int32_t l) { (void)d; (void)l; }
void journal_ocaml_platform_response(const char *d, int32_t l) { (void)d; (void)l; }
void journal_ocaml_platform_failure(const char *d, int32_t l) { (void)d; (void)l; }
void journal_ocaml_set_wakeup_callback(wakeup_cb cb) { (void)cb; }
void journal_ocaml_set_platform_request_callback(platform_request_cb cb) { (void)cb; }"""


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        print(f"build blocked: {error}", file=sys.stderr)
        sys.exit(1)

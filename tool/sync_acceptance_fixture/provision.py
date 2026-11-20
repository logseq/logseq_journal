#!/usr/bin/env python3
"""Provision only new task-owned plaintext acceptance graphs, with explicit consent."""
import argparse
import base64
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import urllib.parse
import uuid

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "_build/owned-plain-fixtures.json"
ORIGIN = "https://api.logseq.io"
PREFIX = "SYNC-ACCEPT-PLAIN-20261119-"
SAFE_ENV = {key: os.environ[key] for key in (
    "PATH", "HOME", "TMPDIR", "OPAM_SWITCH_PREFIX", "CAML_LD_LIBRARY_PATH", "OCAMLPATH"
) if key in os.environ}


def configured_paths(parser, options):
    if (options.registry is None) != (options.work_root is None):
        parser.error("--registry and --work-root must be supplied together")
    if options.work_root is None:
        return REGISTRY, REPO / "_build"
    values = (options.registry, options.work_root)
    paths = [Path(value) for value in values]
    for value, path in zip(values, paths):
        if str(path) != value or str(path.resolve()) != value:
            parser.error("explicit paths must be canonical")
        if not path.is_absolute() or ".." in path.parts:
            parser.error("explicit paths must be absolute without parent traversal")
        if any(parent.is_symlink() for parent in (path, *path.parents)):
            parser.error("explicit paths must not contain symlinks")
    registry_path, work_root = [path.resolve() for path in paths]
    evidence = (Path.home() / "Library/Application Support/Journal isolated evidence").resolve()
    if work_root.parent != evidence or registry_path.parent != work_root:
        parser.error("work root must be a task directory directly under Journal isolated evidence; registry must be directly inside it")
    if registry_path == REGISTRY.resolve():
        parser.error("explicit registry must not be the legacy registry")
    if not work_root.exists():
        work_root.mkdir(mode=0o700)
    status = work_root.lstat()
    if (not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid()
            or stat.S_IMODE(status.st_mode) != 0o700):
        parser.error("work root must be a private owned 0700 directory")
    return registry_path, work_root


def fixture_base(record, registry, work_root):
    stored = Path(record["fixture_directory"])
    base = stored if stored.is_absolute() else REPO / stored
    expected = work_root / ("plain-fixture-" + registry["nonce"] + "-" + record["role"])
    if (".." in stored.parts or base != expected or base.resolve() != expected
            or base.is_symlink() or base.parent.resolve() != work_root):
        raise RuntimeError("fixture directory escaped owned scope")
    status = base.lstat()
    if (not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid()
            or stat.S_IMODE(status.st_mode) != 0o700):
        raise RuntimeError("fixture directory must be private and owned")
    return base


def recorded_preflight(registry, work_root, verify):
    if not re.fullmatch(r"[0-9a-f]{12}", registry["nonce"]):
        raise RuntimeError("invalid registry nonce")
    for record in registry["fixtures"]:
        if (record["role"] not in ("A", "B")
                or record["name"] != PREFIX + registry["nonce"] + "-" + record["role"]):
            raise RuntimeError("registry nonce/role mismatch")
        uuid.UUID(record["id"])
        acknowledgement = record.get("creation_ack")
        if (not acknowledgement or acknowledgement.get("graph-id") != record["id"]
                or acknowledgement.get("graph-e2ee?") is not False
                or record["creator_subject_sha256"] != registry["creator_subject_sha256"]):
            raise RuntimeError("ownership guard failed")
        base = fixture_base(record, registry, work_root)
        path = base / "remote.transit"
        if verify and not record.get("deleted") and (path.exists() or path.is_symlink()):
            raise RuntimeError("remote verification already exists")


def save(registry, registry_path):
    temporary = registry_path.with_name(registry_path.name + ".pending")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(registry, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, registry_path)
    directory = os.open(registry_path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def run(arguments, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, env=SAFE_ENV,
                            cwd=REPO, timeout=90)
    if result.returncode:
        raise RuntimeError(f"subprocess failed: {Path(arguments[0]).name}, exit {result.returncode}")
    return result.stdout


def cli(base, name, command):
    return run(["logseq", "--root-dir", str(base / "cli"), "--config",
                str(base / "cli.edn"), "--graph", name, *command])


def local(base, name):
    (base / "cli").mkdir(mode=0o700)
    config = base / "cli.edn"
    config.write_text('{:auth-path ' + json.dumps(str(base / "absent-auth.json")) + '}\n')
    config.chmod(0o600)
    try:
        cli(base, name, ["graph", "create"])
        cli(base, name, ["graph", "export", "--type", "sqlite", "--file", str(base / "source.sqlite")])
    finally:
        cli(base, name, ["server", "stop"])
    if (base / "absent-auth.json").exists():
        raise RuntimeError("isolated auth file unexpectedly exists")


def native_command(work_root):
    command = [str(REPO / "_build/default/tool/sync_acceptance_fixture/fixture.exe")]
    if work_root != REPO / "_build":
        command.extend(["--work-root", str(work_root)])
    return command


def preflight(base, identifier, label, work_root):
    response = run([*native_command(work_root),
                    str(base / "source.sqlite"), str(base / (label + ".sqlite")),
                    identifier, str(base / (label + ".transit"))])
    report = json.loads(response)
    if not report["public_activation_verified"] or report["encrypted"] or report["bytes"] > 1_000_000:
        raise RuntimeError("public snapshot preflight failed")
    return report


def authenticate():
    payload = json.dumps({"AuthFlow": "USER_PASSWORD_AUTH",
                          "ClientId": "69cs1lgme7p8kbgld8n5kseii6",
                          "AuthParameters": {"USERNAME": os.environ["LOGSEQ_ACCOUNT"],
                                             "PASSWORD": os.environ["LOGSEQ_ACCOUNT_PASSWORD"]}}).encode()
    response = run(["/usr/bin/curl", "--disable", "--silent", "--show-error",
                    "--fail-with-body", "--noproxy", "*", "--connect-timeout", "15", "--max-time", "60",
                    "--header", "content-type: application/x-amz-json-1.1",
                    "--header", "x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth",
                    "--data-binary", "@-", "https://cognito-idp.us-east-1.amazonaws.com/"], payload)
    token = json.loads(response)["AuthenticationResult"]["IdToken"]
    payload_part = token.split(".")[1]
    subject = json.loads(base64.urlsafe_b64decode(payload_part + "=" * (-len(payload_part) % 4)))["sub"]
    return token, hashlib.sha256(subject.encode()).hexdigest()


def request(token, method, path, body=None, snapshot=None, raw=False):
    if not path.startswith("/graphs") and not path.startswith("/sync/"):
        raise RuntimeError("endpoint is outside fixture protocol")
    config = {"url": ORIGIN + path, "request": method,
              "header": "Authorization: Bearer " + token}
    lines = [key + " = " + json.dumps(value) for key, value in config.items()]
    if body is not None:
        lines.extend(['header = "Content-Type: application/json"',
                      "data-binary = " + json.dumps(json.dumps(body))])
    if snapshot is not None:
        lines.extend(['header = "Content-Type: application/transit+json"',
                      "data-binary = " + json.dumps("@" + str(snapshot))])
    result = subprocess.run(["/usr/bin/curl", "--disable", "--silent", "--show-error", "--noproxy", "*",
                             "--compressed", "--max-filesize", "2000000",
                             "--connect-timeout", "15", "--max-time", "60", "--config", "-",
                             "--write-out", "\n%{http_code}"],
                            input=("\n".join(lines) + "\n").encode(), capture_output=True,
                            env=SAFE_ENV, timeout=70)
    if result.returncode:
        raise RuntimeError("HTTP transport outcome indeterminate; no automatic retry")
    response, status = result.stdout.rsplit(b"\n", 1)
    if not 200 <= int(status) < 300:
        raise RuntimeError("HTTP status " + status.decode())
    if raw:
        if response.startswith(b"\x1f\x8b"):
            with gzip.GzipFile(fileobj=io.BytesIO(response)) as stream:
                response = stream.read(1_000_001)
        if len(response) > 1_000_000:
            raise RuntimeError("remote frame exceeds bounded fixture size")
        return response
    return json.loads(response)


def catalog(token):
    return request(token, "GET", "/graphs")["graphs"]


def own_match(record, graphs, creator):
    if (not record.get("creation_ack") or record["creator_subject_sha256"] != creator
            or record["creation_ack"].get("graph-id") != record["id"]
            or record["creation_ack"].get("graph-e2ee?") is not False
            or record["role"] not in ("A", "B")
            or not record["name"].endswith("-" + record["role"])
            or not re.fullmatch(PREFIX + r"[0-9a-f]{12}-[AB]", record["name"])):
        raise RuntimeError("ownership guard failed")
    matches = [graph for graph in graphs if graph["graph-id"] == record["id"]
               and graph["graph-name"] == record["name"]]
    if len(matches) != 1:
        raise RuntimeError("exact acknowledged UUID/name absent or ambiguous")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--create-two-new-plaintext-graphs", action="store_true")
    actions.add_argument("--verify-recorded-owned-fixtures", action="store_true")
    actions.add_argument("--delete-recorded-owned-fixtures", action="store_true")
    parser.add_argument("--registry", help="Private ownership registry inside --work-root (requires both options)")
    parser.add_argument("--work-root", help="Private task directory under Journal isolated evidence (requires --registry)")
    options = parser.parse_args()
    os.umask(0o077)
    registry_path, work_root = configured_paths(parser, options)
    if not registry_path.exists() and not registry_path.is_symlink() and options.create_two_new_plaintext_graphs:
        initial = {"temporary": True, "scope": "task-created plaintext acceptance graphs only", "fixtures": []}
        if options.work_root is not None:
            initial["work_root"] = str(work_root)
        save(initial, registry_path)
    status = registry_path.lstat()
    if (registry_path.is_symlink() or not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) != 0o600
            or status.st_nlink != 1):
        raise RuntimeError("ownership registry must be private and owned")
    registry = json.loads(registry_path.read_text())
    if options.work_root is not None and registry.get("work_root") != str(work_root):
        raise RuntimeError("registry work root does not match configuration")
    if options.verify_recorded_owned_fixtures or options.delete_recorded_owned_fixtures:
        recorded_preflight(registry, work_root, options.verify_recorded_owned_fixtures)
        token, creator = authenticate()
        if registry["creator_subject_sha256"] != creator:
            raise RuntimeError("authenticated creator does not match registry")
        for record in registry["fixtures"]:
            if record.get("deleted"):
                continue
            if record["name"] != PREFIX + registry["nonce"] + "-" + record["role"]:
                raise RuntimeError("registry nonce/role mismatch")
            graph = own_match(record, catalog(token), creator)
            record["cleanup_guard_verified"] = True
            if options.delete_recorded_owned_fixtures:
                receipt = request(token, "DELETE", "/graphs/" + record["id"])
                if receipt.get("deleted") is not True or receipt.get("graph-id") != record["id"]:
                    raise RuntimeError("deletion receipt mismatch")
                record["deleted"] = True
            else:
                if graph["graph-e2ee?"] is not False or graph["graph-ready-for-use?"] is not True:
                    raise RuntimeError("fixture is not ready plaintext")
                base = fixture_base(record, registry, work_root)
                path = base / "remote.transit"
                if path.exists() or path.is_symlink():
                    raise RuntimeError("remote verification already exists")
                frame = request(token, "GET", "/sync/" + record["id"] + "/snapshot/stream", raw=True)
                with path.open("xb") as output:
                    output.write(frame)
                path.chmod(0o600)
                report = json.loads(run([*native_command(work_root),
                                        "--verify-frame", str(path), record["id"], str(record["rows"])]))
                if report["checksum"] != record["checksum"]:
                    raise RuntimeError("fresh remote checksum differs from upload")
                record["remote_fresh_read"] = report
                record["remote_frame_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            save(registry, registry_path)
            print(json.dumps({"id": record["id"], "cleanup_guard_verified": True,
                              "deleted": record.get("deleted", False),
                              "fresh_read": record.get("remote_fresh_read")}))
        return
    if registry["fixtures"] or "nonce" in registry or "indeterminate_creation" in registry:
        raise RuntimeError("registry records a creation attempt; refusing new provisioning; reconcile its existing nonce and outcomes manually")
    nonce = secrets.token_hex(6)
    registry.update(nonce=nonce, temporary=True, origin=ORIGIN,
                    head=run(["git", "rev-parse", "HEAD"]).decode().strip())
    save(registry, registry_path)
    bases = []
    for role in ("A", "B"):
        name = PREFIX + nonce + "-" + role
        base = work_root / ("plain-fixture-" + nonce + "-" + role)
        base.mkdir(mode=0o700)
        bases.append((base, name, role))
        local(base, name)
        report = preflight(base, "92000000-0000-4000-8000-000000000001", "preflight", work_root)
        registry.setdefault("local_preflights", []).append({"name": name, **report})
        save(registry, registry_path)
    token, creator = authenticate()
    registry["creator_subject_sha256"] = creator
    save(registry, registry_path)
    existing = catalog(token)
    if any(graph["graph-name"] in [name for _, name, _ in bases] for graph in existing):
        raise RuntimeError("nonce name already exists; no adoption or mutation allowed")
    try:
        for base, name, role in bases:
            try:
                ack = request(token, "POST", "/graphs", {
                    "graph-name": name, "schema-version": "65", "graph-e2ee?": False,
                    "graph-ready-for-use?": False})
            except Exception:
                matches = [graph for graph in catalog(token) if graph["graph-name"] == name]
                registry["indeterminate_creation"] = {"name": name,
                    "matching_ids": [graph["graph-id"] for graph in matches]}
                save(registry, registry_path)
                raise
            identifier = ack["graph-id"]
            record = {"id": identifier, "name": name, "role": role, "creation_ack": ack,
                      "creator_subject_sha256": creator, "ready": False,
                      "fixture_directory": str(base) if options.work_root is not None else str(base.relative_to(REPO))}
            registry["fixtures"].append(record)
            save(registry, registry_path)
            uuid.UUID(identifier)
            if ack.get("graph-e2ee?") is not False or ack.get("graph-ready-for-use?") is not False:
                raise RuntimeError("creation acknowledgement flags are not plaintext/unready")
            report = preflight(base, identifier, "upload", work_root)
            record.update(report)
            save(registry, registry_path)
            checksum = report["checksum"].removeprefix("checksum:v1:")
            if not re.fullmatch(r"[0-9a-f]{16}", checksum):
                raise RuntimeError("invalid checksum wire representation")
            own_match(record, catalog(token), creator)
            record["upload_receipt"] = request(token, "POST", "/sync/" + identifier
                + "/snapshot/upload?reset=true&finished=true&checksum="
                + urllib.parse.quote(checksum, safe=""), snapshot=base / "upload.transit")
            save(registry, registry_path)
            graph = own_match(record, catalog(token), creator)
            record["catalog"] = {key: graph[key] for key in (
                "graph-id", "graph-name", "schema-version", "graph-e2ee?", "graph-ready-for-use?", "role")}
            if graph["graph-e2ee?"] is not False or graph["graph-ready-for-use?"] is not True:
                raise RuntimeError("uploaded graph not catalog-ready plaintext")
            record["ready"] = True
            record["snapshot_metadata"] = request(token, "GET", "/sync/" + identifier + "/snapshot/download")
            record["snapshot_metadata"] = {key: value for key, value in record["snapshot_metadata"].items()
                                           if key not in ("url", "download-url")}
            save(registry, registry_path)
            print(json.dumps({key: record[key] for key in (
                "id", "name", "ready", "schema", "checksum", "bytes", "rows", "encrypted")}))
    except Exception:
        for record in registry["fixtures"]:
            if record.get("ready") or record.get("deleted"):
                continue
            try:
                graph = own_match(record, catalog(token), creator)
                if graph["graph-ready-for-use?"]:
                    record["cleanup_deferred"] = "server-ready; retained for Main"
                else:
                    receipt = request(token, "DELETE", "/graphs/" + record["id"])
                    record["deleted"] = receipt.get("deleted") is True
                    record["cleanup_guard_verified"] = True
                save(registry, registry_path)
            except Exception:
                record["cleanup_indeterminate"] = True
                save(registry, registry_path)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("fixture provisioning stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

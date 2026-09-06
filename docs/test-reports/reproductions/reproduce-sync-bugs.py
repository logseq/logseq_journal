#!/usr/bin/env python3
"""Run the M01/M02 diagnostic probes against this worktree's actual OCaml code."""
from pathlib import Path
import json
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def run(*args):
    return subprocess.run(args, cwd=REPO, text=True, capture_output=True, check=True)


with tempfile.TemporaryDirectory(prefix="logseq-sync-repro-") as directory:
    scratch = Path(directory)
    directives = []
    for target in ("logseq_db_worker", "logseq_overlay_db"):
        output = run("opam", "exec", "--", "dune", "ocaml", "top", target).stdout
        for line in output.splitlines():
            if line.startswith(("#directory ", "#load ")) and line not in directives:
                directives.append(line)
    if not directives:
        raise RuntimeError("Dune did not emit OCaml dependency directives")
    bootstrap = scratch / "bootstrap.ml"
    bootstrap.write_text("\n".join(directives) + "\n")

    # Load existing test setup without running its registered test suite.
    # Removing the sealed Core alias lets the probe inspect the actual source module.
    contract = (REPO / "logseq_sync/test/core_contract.ml").read_text()
    helpers = scratch / "core_contract_helpers.ml"
    helpers.write_text(contract[contract.index("\n") + 1:contract.index("let rejection_transition effects =")])
    overlay = (REPO / "logseq_overlay_db/test/test_overlay_sync.ml").read_text()
    overlay_helpers = scratch / "overlay_sync_helpers.ml"
    overlay_helpers.write_text(overlay[:overlay.rfind("let () =")])

    replacements = {
        "@@BOOTSTRAP@@": bootstrap,
        "@@WORKER_SOURCE@@": REPO / "logseq_db_worker/lib/effect_runner/effect_runner.ml",
        "@@CORE_SOURCE@@": REPO / "logseq_sync/lib/pure_reducer/core.ml",
        "@@CORE_HELPERS@@": helpers,
        "@@OVERLAY_HELPERS@@": overlay_helpers,
    }
    cases = {
        "probe-m01.ml": "re-acknowledging stale cursor discarded both unseen windows",
        "probe-m02.ml": "later local write requests inspection but cannot release",
        "probe-overlay-delete.ml": "Accept_group followed by replay commits successfully",
    }
    for name, success in cases.items():
        source = (HERE / name).read_text()
        for marker, path in replacements.items():
            source = source.replace('"' + marker + '"', json.dumps(str(path)))
        probe = scratch / name
        probe.write_text(source)
        result = run("opam", "exec", "--", "ocaml", "-noinit", "-noprompt", str(probe))
        print(result.stdout, end="")
        # The OCaml toplevel can exit zero after a source error; require its sentinel.
        if success not in result.stdout:
            raise RuntimeError(f"{name} did not complete:\n{result.stdout}\n{result.stderr}")
    print("All three diagnostic reproductions completed. No live graph was opened.")

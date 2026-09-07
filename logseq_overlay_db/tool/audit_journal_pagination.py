#!/usr/bin/env python3
"""Measure public journal reads in an isolated, instrumented source copy.

Usage: python3 logseq_overlay_db/tool/audit_journal_pagination.py OUTPUT_DIRECTORY
Optional: --mirror-support DIRECTORY --graph-id UUID
No repository build files or installed dependencies are changed.
"""
import argparse
import pathlib
import shlex
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTRUMENTATION = r'''
include Datascript
let metrics : (string, int * int) Hashtbl.t = Hashtbl.create 32
let days = ref []
let add key calls rows =
  let c,r = Option.value (Hashtbl.find_opt metrics key) ~default:(0,0) in
  Hashtbl.replace metrics key (c+calls,r+rows)
let reset () = Hashtbl.clear metrics; days := []
let json () : Yojson.Safe.t = `Assoc (
  ("journal_days", `List (List.sort_uniq Int.compare !days |> List.map (fun n -> `Int n))) ::
  (Hashtbl.fold (fun key (calls,rows) acc ->
    (key, `Assoc ["calls", `Int calls; "rows", `Int rows]) :: acc) metrics []))
let key op index e a v = op ^ ":" ^
  (match index with Eavt -> "Eavt" | Aevt -> "Aevt" | Avet -> "Avet") ^ ":" ^
  (if Option.is_some e then "entity:" else "*:") ^
  Option.value a ~default:"*" ^ (if Option.is_some v then ":value" else "")
let observe k seq = Seq.map (fun (d:datom) -> add k 0 1;
  if d.a = "block/journal-day" then (match d.v with Int day -> days := day :: !days | _ -> ()); d) seq
let datoms db index ?e ?a ?v ?tx () =
  let k = key "datoms" index e a v in add k 1 0;
  Datascript.datoms db index ?e ?a ?v ?tx () |> observe k
let seek_datoms db index ?e ?a ?v ?tx () =
  let k = key "seek" index e a v in add k 1 0;
  Datascript.seek_datoms db index ?e ?a ?v ?tx () |> observe k
let rseek_datoms db index ?e ?a ?v ?tx () =
  let k = key "rseek" index e a v in add k 1 0;
  Datascript.rseek_datoms db index ?e ?a ?v ?tx () |> observe k
let find_datom db index ?e ?a ?v ?tx () =
  let result = Datascript.find_datom db index ?e ?a ?v ?tx () in
  add (key "find" index e a v) 1 (if Option.is_some result then 1 else 0); result
'''


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--mirror-support", type=pathlib.Path)
    parser.add_argument("--graph-id")
    parser.add_argument("--edges", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "source"
    source.mkdir(exist_ok=True)
    for name in ("logseq_db_types", "logseq_db_storage", "logseq_overlay_db"):
        shutil.copytree(ROOT / name, source / name, dirs_exist_ok=True)
    shutil.copy2(ROOT / "dune-project", source / "dune-project")
    fixtures = "logseq_db_worker/test/fixtures/storage"
    shutil.copytree(ROOT / fixtures, source / fixtures, dirs_exist_ok=True)
    storage = source / "logseq_db_storage/lib"
    (storage / "audit_datascript.ml").write_text(INSTRUMENTATION)
    for name in ("database.ml", "authoritative_store.ml"):
        path = source / "logseq_overlay_db/lib" / name
        path.write_text("module Datascript = Logseq_db_storage.Audit_datascript\n" + path.read_text())
    path = source / "logseq_overlay_db/lib/database.ml"
    path.write_text(path.read_text().replace(
        "let page_record_of_entity_with_class ?cache database property_class entity =",
        'let page_record_of_entity_with_class ?cache database property_class entity =\n'
        '  Logseq_db_storage.Audit_datascript.add "full_page_hydration" 1 0;'))
    path = storage / "logseq_sqlite_storage.ml"
    path.write_text(path.read_text().replace(
        "let restore_sqlite address =", 'let restore_sqlite address =\n'
        '          Audit_datascript.add "sqlite_restore" 1 0;'))
    target = "_build/default/logseq_overlay_db/tool/performance_benchmark.exe"
    with (output / "build.log").open("w") as log:
        run(["dune", "build", "--root", str(source), target], stdout=log, stderr=log)
    rules = run(["dune", "rules", "--root", str(source), target], capture_output=True).stdout
    command = shlex.split(rules[rules.rfind("(run\n"):].replace("(", " ").replace(")", " "))[1:]
    libraries = [str(source / "_build/default" / x) if not x.startswith("/") else x
                 for x in command if x.endswith(".cmxa")]
    includes = {str(pathlib.Path(x).parent) for x in libraries}
    includes.update(str(p) for p in (source / "_build/default").glob("**/.*.objs/byte"))
    compiler = [command[0], "-thread"]
    for path in sorted(includes):
        compiler += ["-I", path]
    probe = output / "journal_pagination_probe.ml"
    shutil.copy2(ROOT / "logseq_overlay_db/tool/journal_pagination_probe.ml", probe)
    run(compiler + libraries + [str(probe), "-o", str(output / "probe")])
    if args.mirror_support:
        if not args.graph_id:
            parser.error("--mirror-support requires --graph-id")
        mirror = output / "mirror-support"
        shutil.copytree(args.mirror_support, mirror, dirs_exist_ok=True)
        options = ["mirror", str(mirror), args.graph_id]
    else:
        options = ["edges" if args.edges else "synthetic", tempfile.mkdtemp(prefix="fixtures-", dir=output)]
    with (output / "measurements.jsonl").open("w") as log:
        run([str(output / "probe")] + options, cwd=source, stdout=log)
    print(output / "measurements.jsonl")


if __name__ == "__main__":
    main()

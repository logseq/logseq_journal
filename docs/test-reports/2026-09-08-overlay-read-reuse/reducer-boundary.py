from pathlib import Path
import shlex, subprocess
root=Path.cwd(); out=Path('/tmp/read-reuse-reducer'); out.mkdir(exist_ok=True)
s=(root/'logseq_db_worker/test/test_pure_reducer.ml').read_text().rsplit('let () =',1)[0]
s+='''let () =
 let state, _ = worker_open_graph () in
 let request = { (graph_info_request ()) with Protocol.command = Protocol.V2_get_block { block = uuid "20000000-0000-4000-8000-000000000001"; revision = None } } in
 let next = Core.step state (Core.Graph_request { id = Core.request_id_of_int64 21L; request }) in
 List.iter (fun effect -> print_endline (Core.instruction_diagnostic effect)) next.effects;
 Printf.printf "pending_requests=%d pending_effects=%d\\n" (Core.view next.next).pending_requests (Core.view next.next).pending_effects;
 assert (List.exists (function Core.Run_worker (Core.Request (_, Core.Execute_request {request = actual; _})) -> actual = request | _ -> false) next.effects)
'''
p=out/'probe.ml';p.write_text(s)
r=subprocess.check_output(['dune','rules','logseq_db_worker/test/test_pure_reducer.exe'],text=True)
c=shlex.split(r[r.rfind('(run\n'):].replace('(',' ').replace(')',' '))[1:]
libs=[str(root/'_build/default'/x) if not x.startswith('/') else x for x in c if x.endswith('.cmxa')]
libs.sort(key=lambda x: 0 if x.endswith('/datascript_types.cmxa') else 1)
inc={str(Path(x).parent) for x in libs}|{str(x) for x in (root/'_build/default').glob('**/.*.objs/byte')}
cmd=[c[0],'-thread','-w','-58']
for x in sorted(inc):cmd+=['-I',x]
subprocess.run(cmd+libs+[str(p),'-o',str(out/'probe')],check=True)
subprocess.run([str(out/'probe')],check=True)

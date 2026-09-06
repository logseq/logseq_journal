#use "@@BOOTSTRAP@@";;
#mod_use "@@WORKER_SOURCE@@";;
module R = Effect_runner;;
module P = Logseq_db_worker.Protocol;;
let () = Test_support.with_database ~behavior:"M01 live refresh cursor" (fun database ->
  let subscription, snapshot = Logseq_overlay_db.Database.listen database |> Result.get_ok in
  let generation = (Logseq_overlay_db.Database.snapshot_version snapshot).generation |> Logseq_overlay_db.Types.Generation.to_string in
  Logseq_overlay_db.Database.release_snapshot snapshot;
  let window n : R.change_window = {id=Printf.sprintf "change-window:v1:%d" n;predecessor=Printf.sprintf "revision-%d" n;successor=Printf.sprintf "revision-%d" (n+1);block_uuids=[Test_support.block_uuid];page_uuids=[];structure_interests=[]} in
  let session : R.database_session = {database;subscription;generation;next_window=1;windows=[window 0]} in
  let request command : P.request = {api_version=2;request_id=Test_support.mutation_uuid 950;command} in
  let pull after = R.pull_changes session (request (P.V2_pull_changes {generation;after;limit=256})) generation after 256 in
  let count = function P.V2_response {outcome=P.V2_changes {windows;through;_};_} -> List.length windows,through | _ -> failwith "unexpected pull" in
  let n0,c0=count(pull None) in
  assert(n0=1);
  ignore(R.acknowledge_changes session (request (P.V2_ack_changes {generation;through=c0})) generation c0);
  assert(session.windows=[]);
  session.windows <- [window 1];
  let n1,c1=count(pull (Some c0)) in
  let control,_=count(pull None) in
  Printf.printf "M01 actual worker helpers: first pull=%d ack=%s retained-after-ack=0; second pull(after=%s)=%d through=%s; control pull(None)=%d\n%!" n0 c0 c0 n1 c1 control;
  assert(n1=0 && control=1);
  session.windows <- [window 1;window 2];
  let n2,_=count(pull (Some c0)) in
  assert(n2=0);
  Printf.printf "M01 subsequent push still returns %d windows; retained=%d. Reproduced.\n%!" n2 (List.length session.windows);
  ignore(R.acknowledge_changes session (request (P.V2_ack_changes {generation;through=c0})) generation c0);
  assert(session.windows=[]);
  Printf.printf "M01 re-acknowledging stale cursor discarded both unseen windows. Reproduced.\n%!" );;

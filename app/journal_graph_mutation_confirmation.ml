module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

type purpose =
  | Captured of { block_id : string }
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type read =
  { purpose : purpose; block_id : string
  ; children : Protocol.v2_child_member Rrbvec.t
  ; version : (string * string * string) option; retries : int; stamp : int64 }
type confirmation =
  { purpose : purpose; block_id : string; value : Protocol.v2_block_record
  ; revision : string; page : Graph.page; page_revision : string
  ; scope_revision : string; children : Protocol.v2_child_member Rrbvec.t }
type planning = (Protocol.request, string) result
type step = Continue of planning | Confirmed of confirmation | Failed of string
type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 -> read -> Protocol.command -> Protocol.request }
type t = { latest : (string, int64) Hashtbl.t }
let create () = { latest = Hashtbl.create 32 }
let reset t = Hashtbl.clear t.latest
let current t (read:read) = Hashtbl.find_opt t.latest read.block_id = Some read.stamp
let plan t ~ports (value:read) cursor =
  match Graph.Uuid.of_string value.block_id with
  | Error message -> Error ("block UUID: " ^ message)
  | Ok block ->
    let stamp = ports.now () in
    Hashtbl.replace t.latest value.block_id stamp;
    Ok (ports.plan_read ~source_epoch:stamp {value with stamp}
      (Protocol.V2_get_outline_block_summary {block;limit=Protocol.default_page_size;cursor}))
let start t ~ports purpose =
  let block_id = match purpose with Captured {block_id} | Updated {block_id}
    | Update_conflict_refresh {block_id} | Delete_conflict_refresh {block_id} -> block_id in
  plan t ~ports {purpose;block_id;children=Rrbvec.empty;version=None;retries=0;stamp=0L} None
let retry_stale t ~ports (value:read) =
  if value.retries >= 2 then None else
    Some (plan t ~ports {value with children=Rrbvec.empty;version=None;retries=value.retries+1} None)
let receive_summary t ~ports (summary:read) ~lookup ~page ~items ~next_cursor
    ~scope_revision ~generation ~projection_revision =
  let version = generation,projection_revision,scope_revision in
  if Option.is_some summary.version && summary.version <> Some version then
    match retry_stale t ~ports summary with
    | Some planning -> Continue planning
    | None -> Failed "The target changed repeatedly during confirmation."
  else match (lookup : Protocol.v2_block_lookup), (page : Protocol.v2_page_lookup option) with
    | V2_present_block {value;revision}, Some (V2_present_page {page;revision=page_revision})
      when String.equal (Graph.Uuid.to_string value.block.uuid) summary.block_id
        && Graph.Uuid.equal value.block.page page.uuid
        && List.to_seq items |> Seq.for_all (fun (item:Protocol.v2_child_member)->
          Graph.Uuid.equal item.value.block.parent value.block.uuid
          && Graph.Uuid.equal item.value.block.page page.uuid) ->
      let children = Rrbvec.append_list summary.children items in
      (match next_cursor with
       | Some cursor -> Continue (plan t ~ports {summary with children;version=Some version} (Some cursor))
       | None -> Confirmed {purpose=summary.purpose;block_id=summary.block_id;value;revision;
           page;page_revision;scope_revision;children})
    | _ -> Failed "The canonical mutation target is unavailable or mismatched."
let reference_fragment (summary:read) ~target ~final_children =
  Rrbvec.push_front
    (Rrbvec.map (fun (item:Protocol.v2_child_member)->item.value)
      (Rrbvec.append_list summary.children final_children)) target

module T = Logseq_db_worker_test_support.Test_support
module C = Logseq_db_worker.Sync_catalog
module Uuid = Logseq_db_worker.Graph_types.Uuid

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let id text = Uuid.of_string text |> Result.get_ok

let graph graph_id name =
  C.
    { graph_id = id graph_id
    ; name
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted = false
    }
;;

let test_decodes_only_ready_catalog_entries () =
  let source =
    {|{"graphs":[{"graph-id":"10000000-0000-4000-8000-000000000001","graph-name":"Ready","schema-version":"65.33","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"10000000-0000-4000-8000-000000000002","graph-name":"Uploading","schema-version":"65","graph-e2ee?":true,"graph-ready-for-use?":false}]}|}
  in
  match C.decode source with
  | Error message -> T.fail "valid catalog failed: %s" message
  | Ok [ entry ] ->
    T.require (String.equal entry.name "Ready") "wrong catalog entry";
    T.require
      (entry.schema.major = 65 && entry.schema.minor = 33 && entry.schema.exact)
      "schema was not decoded exactly";
    T.require (not entry.encrypted) "encryption flag changed"
  | Ok _ -> T.fail "catalog retained a graph that was not ready"
;;

let test_rejects_malformed_catalog () =
  List.iter
    (fun source ->
       T.require (Result.is_error (C.decode source)) "malformed catalog was accepted")
    [ "{}"
    ; {|{"graphs":[{"graph-id":"bad","graph-name":"Graph","schema-version":"65.33","graph-ready-for-use?":true}]}|}
    ; {|{"graphs":[{"graph-id":"10000000-0000-4000-8000-000000000001","graph-name":"Graph","schema-version":"65.x","graph-ready-for-use?":true}]}|}
    ; {|{"graphs":[{"graph-id":"10000000-0000-4000-8000-000000000001","graph-name":"","schema-version":"65.33","graph-ready-for-use?":true}]}|}
    ]
;;

let test_merge_selection_mirror_status_and_secret_free_round_trip () =
  let first = graph "10000000-0000-4000-8000-000000000001" "First" in
  let second = graph "10000000-0000-4000-8000-000000000002" "Second" in
  let cache =
    C.create_cache
      ~user_id:"user-1"
      ~base_url:"https://api.logseq.io"
      ~graphs:[ first; second ]
      ~selected_graph:(Some first.graph_id)
    |> fun cache -> C.set_mirror_status cache first.graph_id Ready
  in
  T.require (C.mirror_status cache first.graph_id = Ready) "ready mirror was lost";
  let refreshed_first = { first with name = "Renamed" } in
  let cache = C.merge cache [ refreshed_first ] in
  T.require
    (C.selected_graph cache = Some first.graph_id)
    "authorized selection was not retained";
  T.require
    (C.mirror_status cache first.graph_id = Ready)
    "catalog refresh discarded mirror status";
  let json = C.to_yojson cache in
  let encoded = Yojson.Safe.to_string json in
  T.require (not (String.equal encoded "null")) "cache was not serialized";
  T.require
    (not (contains encoded "idToken"))
    "cache serialization unexpectedly contains credential-like text";
  let decoded = C.of_yojson json |> Result.get_ok in
  T.require
    (C.selected_graph decoded = Some first.graph_id)
    "cache round trip changed selection";
  let removed = C.merge cache [ second ] in
  T.require
    (C.selected_graph removed = None)
    "selection survived removal from authorized catalog";
  T.require
    (Result.is_error (C.select removed first.graph_id))
    "unauthorized graph selection was accepted"
;;

let () =
  test_decodes_only_ready_catalog_entries ();
  test_rejects_malformed_catalog ();
  test_merge_selection_mirror_status_and_secret_free_round_trip ()
;;

module T = Logseq_db_worker_test_support.Test_support
module Admission = Logseq_db_storage.Admission
module Config = Logseq_db_worker.Config
module Graph_types = Logseq_db_types.Graph_types

let uuid value =
  match Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let graph_id = uuid "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let other_graph_id = uuid "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
let local_graph_id = uuid "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

let checkpoint =
  Logseq_db_types.Sync_checkpoint.create
    ~graph_id
    ~schema:Graph_types.{ major = 65; minor = 33 }
    ~applied_server_t:41
    ~checksum:"0123456789abcdef"
  |> Result.get_ok
;;

let config () =
  Config.create
    ~application_support_directory:"/tmp/logseq-journal-support"
    ~target:
      (Synced_mirror
         { graph_id
         ; graph_name = "团队 / Notes"
         ; graph_dir = "/tmp/logseq-journal-support/synced-graph"
         ; database_path = "/tmp/logseq-journal-support/synced-graph/db.sqlite"
         ; checkpoint
         })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:262_144
    ~default_page_size:50
;;

let synced_config_round_trip_case () =
  let config = config () |> Result.get_ok in
  let encoded = Config.to_yojson config in
  let target = Yojson.Safe.Util.member "target" encoded in
  let open Yojson.Safe.Util in
  T.require
    (target |> member "kind" |> to_string = "syncedMirror")
    "synced target kind changed";
  T.require
    (target |> member "graphId" |> to_string = Graph_types.Uuid.to_string graph_id)
    "synced graph id changed";
  T.require
    (target
     |> member "databasePath"
     |> to_string
     = "/tmp/logseq-journal-support/synced-graph/db.sqlite")
    "database path changed";
  match Config.of_yojson encoded with
  | Ok
      { target =
          Synced_mirror
            { graph_id = decoded
            ; graph_name
            ; graph_dir
            ; database_path
            ; checkpoint = decoded_checkpoint
            }
      ; _
      } ->
    T.require (Graph_types.Uuid.equal decoded graph_id) "graph id did not round trip";
    T.require (String.equal graph_name "团队 / Notes") "graph name did not round trip";
    T.require
      (String.equal (Filename.concat graph_dir "db.sqlite") database_path)
      "database path escaped the graph directory";
    T.require
      (Logseq_db_types.Sync_checkpoint.equal decoded_checkpoint checkpoint)
      "checkpoint did not round trip"
  | Ok _ -> T.fail "synced config decoded to another target"
  | Error message -> T.fail "synced config did not decode: %s" message
;;

let synced_config_rejection_case () =
  let base target =
    `Assoc
      [ "applicationSupportDirectory", `String "/tmp/logseq-journal-support"
      ; "target", target
      ; "compatibilityProfile", `String "logseq-65.33-or-newer"
      ; "responseBudgetBytes", `Int 262_144
      ; "defaultPageSize", `Int 50
      ]
  in
  let reject label target =
    match Config.of_yojson (base target) with
    | Error _ -> ()
    | Ok _ -> T.fail "%s was accepted" label
  in
  reject
    "obsolete path-free synced graph target"
    (`Assoc
        [ "kind", `String "syncedGraph"
        ; "graphId", `String (Graph_types.Uuid.to_string graph_id)
        ; "graphName", `String "Notes"
        ]);
  let encoded = Config.to_yojson (config () |> Result.get_ok) in
  let target = Yojson.Safe.Util.member "target" encoded in
  let escaped =
    match target with
    | `Assoc fields ->
      `Assoc
        (("databasePath", `String "/tmp/elsewhere/db.sqlite")
         :: List.remove_assoc "databasePath" fields)
    | _ -> assert false
  in
  reject "database path outside graph directory" escaped
;;

let observed ?(remote_flag = Admission.Boolean true) ?(rtc_graph_uuid = Some graph_id) () =
  Admission.
    { schema = Graph_types.{ major = 65; minor = 33 }
    ; local_graph_uuid = Some local_graph_id
    ; remote_flag
    ; rtc_graph_uuid
    ; client_ops_graph_uuid = None
    ; codec_lossless = true
    ; required_schema_present = true
    }
;;

let synced_admission_case () =
  match Admission.admit ~target:(Synced_target graph_id) (observed ()) with
  | Error _ -> T.fail "matching upstream remote identity was rejected"
  | Ok facts ->
    T.require (List.mem Graph_types.Remote_flag_true facts) "remote flag fact is missing";
    T.require
      (List.mem (Graph_types.Synced_graph_identity graph_id) facts)
      "synced graph identity fact is missing"
;;

let synced_admission_rejection_case () =
  let reject label observed =
    match Admission.admit ~target:(Synced_target graph_id) observed with
    | Error _ -> ()
    | Ok _ -> T.fail "%s was admitted" label
  in
  reject "missing remote flag" (observed ~remote_flag:Absent ());
  reject "false remote flag" (observed ~remote_flag:(Boolean false) ());
  reject "missing RTC graph identity" (observed ~rtc_graph_uuid:None ());
  reject
    "mismatched RTC graph identity"
    (observed ~rtc_graph_uuid:(Some other_graph_id) ());
  match Admission.admit ~target:Local_target (observed ()) with
  | Error Admission.Remote_graph -> ()
  | Error _ -> T.fail "local target returned the wrong remote identity error"
  | Ok _ -> T.fail "local target admitted a remote graph"
;;

let () =
  T.run
    "synced config and admission"
    [ T.case "round trip an explicit synced mirror" synced_config_round_trip_case
    ; T.case "reject obsolete or escaping synced targets" synced_config_rejection_case
    ; T.case "admit the matching upstream remote identity" synced_admission_case
    ; T.case
        "reject ambiguous synced and local identities"
        synced_admission_rejection_case
    ]
;;

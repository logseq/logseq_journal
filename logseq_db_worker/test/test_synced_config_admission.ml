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

let internal_target_rejection_case () =
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
    "internal synced mirror"
    (`Assoc
        [ "kind", `String ("synced" ^ "Mirror")
        ; "graphId", `String (Graph_types.Uuid.to_string graph_id)
        ; "graphName", `String "Notes"
        ; "graphDir", `String "/tmp/Notes"
        ; "databasePath", `String "/tmp/Notes/db.sqlite"
        ; ( "checkpoint"
          , `Assoc
              [ "appliedServerT", `Int 41
              ; "checksum", `String "0123456789abcdef"
              ; "schemaMajor", `Int 65
              ; "schemaMinor", `Int 33
              ; "status", `String "active"
              ; "lastError", `Null
              ] )
        ])
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
    [ T.case "reject internal synced mirror startup" internal_target_rejection_case
    ; T.case "admit the matching upstream remote identity" synced_admission_case
    ; T.case
        "reject ambiguous synced and local identities"
        synced_admission_rejection_case
    ]
;;

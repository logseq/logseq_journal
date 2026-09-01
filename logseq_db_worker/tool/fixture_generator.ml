open Logseq_db_types.Mutation

type mode =
  | Runtime_flow
  | Runtime_flow_with_pagination
  | Runtime_flow_with_persistence_failure

type generated =
  { support_root : string
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t
  ; graph_dir : string
  ; user_id : string
  ; base_url : string
  ; expected_timeline_text : string
  }

module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok

let rec ensure_directory_tree path =
  if Sys.file_exists path
  then ()
  else (
    ensure_directory_tree (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let install_catalog_fixture ~support_root ~user_id ~base_url ~graph_id ~encrypted =
  let root = Filename.concat support_root "logseq-db-worker/sync-catalogs" in
  ensure_directory_tree root;
  let digest =
    Digestif.SHA256.digest_string (user_id ^ "\000" ^ base_url) |> Digestif.SHA256.to_hex
  in
  let graph_id = Logseq_db_types.Graph_types.Uuid.to_string graph_id in
  let rec instantiate = function
    | `String "__BASE_URL__" -> `String base_url
    | `String "__GRAPH_ID__" -> `String graph_id
    | `String "__USER_ID__" -> `String user_id
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              ( name
              , if String.equal name "encrypted"
                then `Bool encrypted
                else instantiate value ))
           fields)
    | `List values -> `List (List.map instantiate values)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
  in
  let json =
    Logseq_db_worker_test_support.Test_support.fixture
      "sync/encrypted-catalog-template.json"
    |> Yojson.Safe.from_file
    |> instantiate
  in
  Yojson.Safe.to_file (Filename.concat root (digest ^ ".json")) json
;;

let attachment graph_id graph_dir checkpoint =
  Logseq_db_worker.Engine.
    { graph_id
    ; graph_name = "runtime-flow-source"
    ; graph_dir
    ; database_path = Filename.concat graph_dir "db.sqlite"
    ; checkpoint
    }
;;

let apply_mutation engine checkpoint mutation =
  let identity = Logseq_db_types.Mutation.identify mutation in
  let prepared =
    Logseq_db_worker.Engine.prepare_managed_mutation engine ~identity mutation
    |> Result.get_ok
  in
  let precondition =
    Logseq_db_worker.Engine.authoritative_precondition engine |> Result.get_ok
  in
  match
    Logseq_db_worker.Engine.apply_authoritative
      engine
      ~expected_precondition:precondition
      [ Logseq_db_worker.Engine.prepared_mutation_operations prepared ]
      ~projection_transactions:[]
      ~checkpoint
      ~outbox_records:[]
  with
  | Ok _ -> ()
  | Error Authoritative_conflict -> failwith "fixture authoritative commit conflicted"
  | Error (Authoritative_apply_failed message) -> failwith message
;;

let seed_pagination_graph ~support_root ~graph_id ~graph_dir ~checkpoint =
  let config = Adapter_fixture.config support_root graph_id in
  let engine =
    Logseq_db_worker.Engine.open_
      ~dependencies:Adapter_fixture.dependencies
      ~response_budget_bytes:config.response_budget_bytes
      (attachment graph_id graph_dir checkpoint)
    |> Result.get_ok
  in
  let sequence = ref 1 in
  let context () =
    let number = !sequence in
    incr sequence;
    { mutation_id = uuid (Printf.sprintf "93000000-0000-4000-8000-%012x" number)
    ; expected_basis = Option.get (Logseq_db_worker.Engine.basis engine)
    }
  in
  let seed_day index day title row_count row_prefix =
    let page =
      uuid
        (Printf.sprintf
           "00000001-%04d-%04d-0000-000000000000"
           (day / 10_000)
           (day mod 10_000))
    in
    apply_mutation
      engine
      checkpoint
      (Page
         (Create_page
            { title
            ; kind = Create_journal_page { journal_day = day; supplied_uuid = Some page }
            ; context = context ()
            }));
    let roots =
      List.init row_count (fun offset ->
        let row = offset + 1 in
        { uuid =
            uuid (Printf.sprintf "94000000-0000-4000-8000-%012x" ((index * 1_000) + row))
        ; title = Printf.sprintf "%s row %02d" row_prefix row
        ; children = []
        })
    in
    apply_mutation
      engine
      checkpoint
      (Structural
         (Insert_blocks
            { roots; position = Relative (Last_child page); context = context () }))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
    (fun () ->
       seed_day 1 20260807 "Aug 7th, 2026" 1 "Pagination today";
       seed_day 2 20260806 "Aug 6th, 2026" 1 "Pagination day six";
       seed_day 3 20260805 "Aug 5th, 2026" 70 "Pagination day five";
       seed_day 4 20260804 "Aug 4th, 2026" 70 "Pagination day four")
;;

let create_with_catalog_encryption ~support_root ~mode ~encrypted =
  try
    if Filename.is_relative support_root
    then Error "support root must be absolute"
    else if not (Sys.file_exists support_root && Sys.is_directory support_root)
    then Error "support root must be an existing directory"
    else (
      let support_root = Unix.realpath support_root in
      let graph_id = uuid "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" in
      let graph_id_text = Logseq_db_types.Graph_types.Uuid.to_string graph_id in
      let root = Filename.concat support_root "logseq-db-worker/synced-graphs" in
      let graph_dir = Filename.concat root graph_id_text in
      if Sys.file_exists graph_dir
      then Error "managed warm-start mirror already exists"
      else (
        ensure_directory_tree root;
        let created = Adapter_fixture.create_oracle_graph root graph_id_text in
        if not (String.equal created graph_dir)
        then failwith "managed mirror path changed";
        let checkpoint = Adapter_fixture.prepare_mirror graph_dir graph_id in
        (match mode with
         | Runtime_flow -> ()
         | Runtime_flow_with_pagination ->
           seed_pagination_graph ~support_root ~graph_id ~graph_dir ~checkpoint
         | Runtime_flow_with_persistence_failure ->
           Adapter_fixture.install_mutation_write_failure graph_dir);
        let base_url = "https://api.logseq.io" in
        let user_id = "fixture-" ^ Digest.to_hex (Digest.string support_root) in
        install_catalog_fixture ~support_root ~user_id ~base_url ~graph_id ~encrypted;
        Ok
          { support_root
          ; graph_id
          ; graph_dir
          ; user_id
          ; base_url
          ; expected_timeline_text = "Pagination today row 01"
          }))
  with
  | Unix.Unix_error (error, operation, path) ->
    Error
      (Printf.sprintf
         "fixture filesystem operation failed: %s(%s): %s"
         operation
         path
         (Unix.error_message error))
  | Failure message -> Error message
;;

let create ~support_root ~mode =
  create_with_catalog_encryption ~support_root ~mode ~encrypted:true
;;

let create_unencrypted_warm_start ~support_root =
  create_with_catalog_encryption ~support_root ~mode:Runtime_flow ~encrypted:false
;;

let create_encrypted_warm_start ~support_root =
  create ~support_root ~mode:Runtime_flow_with_pagination
;;

let to_yojson generated =
  `Assoc
    [ "formatVersion", `Int 1
    ; "supportRoot", `String generated.support_root
    ; "baseUrl", `String generated.base_url
    ; "userId", `String generated.user_id
    ; "graphId", `String (Logseq_db_types.Graph_types.Uuid.to_string generated.graph_id)
    ; "graphDir", `String generated.graph_dir
    ; "expectedTimelineText", `String generated.expected_timeline_text
    ]
;;

let managed_to_yojson = to_yojson

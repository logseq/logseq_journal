module T = Logseq_db_worker_test_support.Test_support
module Engine = Logseq_db_worker.Engine
module Snapshot = Logseq_db_worker__Snapshot

let expected_commit = "4f21d068aed43bb2ea5823247cae73ecdd8d60f8"
let page_uuid = "11111111-1111-4111-8111-111111111111"
let parent_uuid = "22222222-2222-4222-8222-222222222222"
let first_child_uuid = "33333333-3333-4333-8333-333333333334"
let second_child_uuid = "44444444-4444-4444-8444-444444444445"
let sibling_uuid = "55555555-5555-4555-8555-555555555555"
let inserted_uuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let continuation_uuid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
let created_page_uuid = "66666666-6666-4666-8666-666666666666"
let created_class_uuid = "77777777-7777-4777-8777-777777777777"
let created_journal_uuid = "00000001-2024-0102-0000-000000000000"
let page_continuation_uuid = "88888888-8888-4888-8888-888888888888"
let closed_value_uuid = "93000000-0000-4000-8000-000000000001"
let associated_value_uuid = "93000000-0000-4000-8000-000000000002"
let checkbox_property = "user.property/parity-checkbox"
let many_property = "user.property/parity-many"
let default_property = "user.property/parity-default"
let created_property = "user.property/parity-created"

type structural_case =
  | Save
  | Insert
  | Move
  | Move_up
  | Indent
  | Outdent
  | Delete

type page_case =
  | Ordinary_create
  | Journal_create
  | Class_create
  | Rename
  | Recycle_delete
  | Restore
  | Permanent_delete

type property_case =
  | Property_upsert
  | Property_set
  | Property_remove
  | Property_batch_append
  | Property_batch_replace
  | Property_batch_remove
  | Closed_add
  | Closed_update
  | Closed_associate
  | Closed_delete
  | Class_property_add
  | Class_property_remove

let case_name = function
  | Save -> "save"
  | Insert -> "insert"
  | Move -> "move"
  | Move_up -> "move-up"
  | Indent -> "indent"
  | Outdent -> "outdent"
  | Delete -> "delete"
;;

let page_case_name = function
  | Ordinary_create -> "create-ordinary"
  | Journal_create -> "create-journal"
  | Class_create -> "create-class"
  | Rename -> "rename"
  | Recycle_delete -> "delete"
  | Restore -> "restore"
  | Permanent_delete -> "permanent-delete"
;;

let property_case_name = function
  | Property_upsert -> "upsert"
  | Property_set -> "set"
  | Property_remove -> "remove"
  | Property_batch_append -> "batch-append"
  | Property_batch_replace -> "batch-replace"
  | Property_batch_remove -> "batch-remove"
  | Closed_add -> "closed-add"
  | Closed_update -> "closed-update"
  | Closed_associate -> "closed-associate"
  | Closed_delete -> "closed-delete"
  | Class_property_add -> "class-add"
  | Class_property_remove -> "class-remove"
;;

let uuid value =
  match Logseq_db_worker.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "invalid test UUID %s: %s" value message
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory f =
  let path = Filename.temp_file "logseq-db-worker-cross-runtime-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let copy_file source target =
  let input = open_in_bin source in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
       let output = open_out_bin target in
       Fun.protect
         ~finally:(fun () -> close_out_noerr output)
         (fun () ->
            let buffer = Bytes.create 65_536 in
            let rec loop () =
              match Stdlib.input input buffer 0 (Bytes.length buffer) with
              | 0 -> ()
              | count ->
                Stdlib.output output buffer 0 count;
                loop ()
            in
            loop ()))
;;

let absolute path =
  if Filename.is_relative path then Filename.concat T.root path else path
;;

type options =
  { oracle_repo : string
  ; expected_oracle_commit : string
  ; interop_repo : string
  ; expected_interop_commit : string
  ; slice : string
  }

let options () =
  let rec loop oracle_repo oracle_commit interop_repo interop_commit slice index =
    if index >= Array.length Sys.argv
    then
      { oracle_repo = absolute oracle_repo
      ; expected_oracle_commit = oracle_commit
      ; interop_repo = absolute interop_repo
      ; expected_interop_commit = interop_commit
      ; slice
      }
    else (
      match Sys.argv.(index) with
      | "--oracle-logseq-repo" when index + 1 < Array.length Sys.argv ->
        loop
          Sys.argv.(index + 1)
          oracle_commit
          interop_repo
          interop_commit
          slice
          (index + 2)
      | "--expected-oracle-commit" when index + 1 < Array.length Sys.argv ->
        loop oracle_repo Sys.argv.(index + 1) interop_repo interop_commit slice (index + 2)
      | "--interop-logseq-repo" when index + 1 < Array.length Sys.argv ->
        loop
          oracle_repo
          oracle_commit
          Sys.argv.(index + 1)
          interop_commit
          slice
          (index + 2)
      | "--expected-interop-commit" when index + 1 < Array.length Sys.argv ->
        loop oracle_repo oracle_commit interop_repo Sys.argv.(index + 1) slice (index + 2)
      | "--slice" when index + 1 < Array.length Sys.argv ->
        loop
          oracle_repo
          oracle_commit
          interop_repo
          interop_commit
          Sys.argv.(index + 1)
          (index + 2)
      | argument -> T.fail "unknown cross-runtime argument: %s" argument)
  in
  loop
    "../logseq-oracle-4f21d068"
    expected_commit
    "../logseq-worker-interop"
    ""
    "structural"
    1
;;

let command_output program arguments =
  let stdout_path = Filename.temp_file "logseq-db-worker-command-" ".stdout" in
  let stderr_path = Filename.temp_file "logseq-db-worker-command-" ".stderr" in
  let stdout_fd = Unix.openfile stdout_path [ Unix.O_WRONLY; O_TRUNC ] 0o600 in
  let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; O_TRUNC ] 0o600 in
  let argv = Array.of_list (program :: arguments) in
  let pid = Unix.create_process program argv Unix.stdin stdout_fd stderr_fd in
  Unix.close stdout_fd;
  Unix.close stderr_fd;
  let _, status = Unix.waitpid [] pid in
  let read path =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let stdout = read stdout_path in
  let stderr = read stderr_path in
  Sys.remove stdout_path;
  Sys.remove stderr_path;
  match status with
  | Unix.WEXITED 0 -> stdout
  | WEXITED code ->
    T.fail "%s exited %d\nstdout:\n%s\nstderr:\n%s" program code stdout stderr
  | WSIGNALED signal -> T.fail "%s was killed by signal %d\n%s" program signal stderr
  | WSTOPPED signal -> T.fail "%s was stopped by signal %d\n%s" program signal stderr
;;

let trim value = String.trim value
let oracle_script = Filename.concat T.root "logseq_db_worker/tool/logseq_oracle.cljs"

let run_oracle options arguments =
  ignore
    (command_output
       "pnpm"
       ([ "--dir"
        ; Filename.concat options.oracle_repo "deps/db"
        ; "exec"
        ; "nbb-logseq"
        ; oracle_script
        ]
        @ arguments
        @ [ "--expected-logseq-commit"; options.expected_oracle_commit ]))
;;

let oracle_structural options ~case ?database_input ~database_output ~projection_output ()
  =
  run_oracle
    options
    ([ "structural"
     ; "--case"
     ; case
     ; "--database-output"
     ; database_output
     ; "--output"
     ; projection_output
     ]
     @ Option.fold
         ~none:[]
         ~some:(fun path -> [ "--database-input"; path ])
         database_input)
;;

let oracle_page options ~case ?database_input ~database_output ~projection_output () =
  run_oracle
    options
    ([ "pages"
     ; "--case"
     ; case
     ; "--database-output"
     ; database_output
     ; "--output"
     ; projection_output
     ]
     @ Option.fold
         ~none:[]
         ~some:(fun path -> [ "--database-input"; path ])
         database_input)
;;

let oracle_property options ~case ?database_input ~database_output ~projection_output () =
  run_oracle
    options
    ([ "properties"
     ; "--case"
     ; case
     ; "--database-output"
     ; database_output
     ; "--output"
     ; projection_output
     ]
     @ Option.fold
         ~none:[]
         ~some:(fun path -> [ "--database-input"; path ])
         database_input)
;;

let compare_projections expected actual =
  ignore
    (command_output
       (Filename.concat
          T.root
          "_build/default/logseq_db_worker/tool/compare_canonical_graphs.exe")
       [ "--expected"; expected; "--actual"; actual ])
;;

let oracle_metadata () =
  match T.read_json (T.fixture "expected/oracle-worker-route-smoke.json") with
  | `Assoc fields ->
    let source = List.assoc "source" fields in
    let source_fields =
      match source with
      | `Assoc values -> values
      | _ -> T.fail "source is not object"
    in
    T.require
      (List.assoc_opt "logseqCommit" source_fields = Some (`String expected_commit))
      "oracle commit changed";
    T.require
      (List.assoc_opt "minimumSupportedSchema" source_fields = Some (`String "65.33"))
      "minimum schema changed"
  | _ -> T.fail "oracle golden is not an object"
;;

let dependencies =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 'x'
    }
;;

let config support token =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Snapshot { token })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:262_144
      ~default_page_size:50
  with
  | Ok config -> config
  | Error message -> T.fail "invalid cross-runtime config: %s" message
;;

let native_config support graph_dir =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Native_local_graph { graph_name = Filename.basename graph_dir; graph_dir })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:262_144
      ~default_page_size:50
  with
  | Ok config -> config
  | Error message -> T.fail "invalid native cross-runtime config: %s" message
;;

type child_process =
  { pid : int
  ; stdout_path : string
  ; stderr_path : string
  ; mutable reaped : Unix.process_status option
  }

let spawn_process program arguments =
  let stdout_path = Filename.temp_file "logseq-db-worker-daemon-" ".stdout" in
  let stderr_path = Filename.temp_file "logseq-db-worker-daemon-" ".stderr" in
  let stdout_fd = Unix.openfile stdout_path [ Unix.O_WRONLY; O_TRUNC ] 0o600 in
  let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; O_TRUNC ] 0o600 in
  let argv = Array.of_list (program :: arguments) in
  let pid = Unix.create_process program argv Unix.stdin stdout_fd stderr_fd in
  Unix.close stdout_fd;
  Unix.close stderr_fd;
  { pid; stdout_path; stderr_path; reaped = None }
;;

let read_file_if_present path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  with
  | Sys_error _ -> ""
;;

let poll_child child =
  match child.reaped with
  | Some status -> Some status
  | None ->
    let pid, status = Unix.waitpid [ Unix.WNOHANG ] child.pid in
    if pid = 0
    then None
    else (
      child.reaped <- Some status;
      Some status)
;;

let wait_child child =
  match child.reaped with
  | Some status -> status
  | None ->
    let _, status = Unix.waitpid [] child.pid in
    child.reaped <- Some status;
    status
;;

let cleanup_child child =
  (match poll_child child with
   | Some _ -> ()
   | None ->
     (try Unix.kill child.pid Sys.sigterm with
      | Unix.Unix_error _ -> ());
     ignore (wait_child child));
  List.iter
    (fun path ->
       try Sys.remove path with
       | Sys_error _ -> ())
    [ child.stdout_path; child.stderr_path ]
;;

let parse_server_port path =
  let lines = read_file_if_present path |> String.split_on_char '\n' in
  List.find_map
    (fun line ->
       match String.split_on_char ' ' (String.trim line) with
       | [ pid; port ] ->
         (match int_of_string_opt pid, int_of_string_opt port with
          | Some pid, Some port when pid > 0 && port > 0 -> Some port
          | _ -> None)
       | _ -> None)
    (List.rev lines)
;;

let wait_for_server child server_list =
  let deadline = Unix.gettimeofday () +. 30. in
  let rec loop () =
    match poll_child child, parse_server_port server_list with
    | _, Some port -> port
    | Some status, None ->
      T.fail
        "interop daemon exited before readiness (%s)\nstdout:\n%s\nstderr:\n%s"
        (match status with
         | Unix.WEXITED code -> Printf.sprintf "exit %d" code
         | WSIGNALED signal -> Printf.sprintf "signal %d" signal
         | WSTOPPED signal -> Printf.sprintf "stopped %d" signal)
        (read_file_if_present child.stdout_path)
        (read_file_if_present child.stderr_path)
    | None, None when Unix.gettimeofday () >= deadline ->
      T.fail
        "timed out waiting for interop daemon\nstdout:\n%s\nstderr:\n%s"
        (read_file_if_present child.stdout_path)
        (read_file_if_present child.stderr_path)
    | None, None ->
      Unix.sleepf 0.05;
      loop ()
  in
  loop ()
;;

let snapshot_error = function
  | Snapshot.Invalid_catalog_root -> "invalid catalog root"
  | Invalid_inbox_entry -> "invalid inbox entry"
  | Source_missing -> "source missing"
  | Manifest_mismatch -> "manifest mismatch"
  | Token_unknown -> "token unknown"
  | Path_escape -> "path escape"
  | Symlink_rejected -> "symlink rejected"
  | Hard_link_rejected -> "hard link rejected"
  | Publish_failed message -> "publish failed: " ^ message
;;

let with_engine_for_database database f =
  with_temp_directory (fun support ->
    let source = Filename.concat support "source-graph" in
    Unix.mkdir source 0o700;
    copy_file database (Filename.concat source "db.sqlite");
    let catalog =
      match Snapshot.create_catalog ~application_support_directory:support with
      | Ok catalog -> catalog
      | Error _ -> T.fail "unable to create cross-runtime snapshot catalog"
    in
    let token =
      match Snapshot.create catalog ~source_graph_dir:source with
      | Ok token -> token
      | Error error ->
        T.fail "unable to snapshot the oracle database: %s" (snapshot_error error)
    in
    let resolved =
      match Snapshot.resolve catalog token with
      | Ok resolved -> resolved
      | Error _ -> T.fail "unable to resolve the cross-runtime snapshot"
    in
    let engine =
      match Engine.open_ ~dependencies (config support token) with
      | Ok engine -> engine
      | Error error ->
        T.fail
          "unable to open the oracle database in OCaml: %s (%s)"
          (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code error))
          (Logseq_db_worker.Error.message error)
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () -> f engine resolved);
    copy_file (Filename.concat resolved.graph_dir "db.sqlite") database)
;;

let request_id = uuid "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

let mutation_id = function
  | Save -> uuid "d0000000-0000-4000-8000-000000000001"
  | Insert -> uuid "d0000000-0000-4000-8000-000000000002"
  | Move -> uuid "d0000000-0000-4000-8000-000000000003"
  | Move_up -> uuid "d0000000-0000-4000-8000-000000000004"
  | Indent -> uuid "d0000000-0000-4000-8000-000000000005"
  | Outdent -> uuid "d0000000-0000-4000-8000-000000000006"
  | Delete -> uuid "d0000000-0000-4000-8000-000000000007"
;;

let page_mutation_id = function
  | Ordinary_create -> uuid "e0000000-0000-4000-8000-000000000001"
  | Journal_create -> uuid "e0000000-0000-4000-8000-000000000002"
  | Class_create -> uuid "e0000000-0000-4000-8000-000000000003"
  | Rename -> uuid "e0000000-0000-4000-8000-000000000004"
  | Recycle_delete -> uuid "e0000000-0000-4000-8000-000000000005"
  | Restore -> uuid "e0000000-0000-4000-8000-000000000006"
  | Permanent_delete -> uuid "e0000000-0000-4000-8000-000000000007"
;;

let property_mutation_id = function
  | Property_upsert -> uuid "91000000-0000-4000-8000-000000000001"
  | Property_set -> uuid "91000000-0000-4000-8000-000000000002"
  | Property_remove -> uuid "91000000-0000-4000-8000-000000000003"
  | Property_batch_append -> uuid "91000000-0000-4000-8000-000000000004"
  | Property_batch_replace -> uuid "91000000-0000-4000-8000-000000000005"
  | Property_batch_remove -> uuid "91000000-0000-4000-8000-000000000006"
  | Closed_add -> uuid "91000000-0000-4000-8000-000000000007"
  | Closed_update -> uuid "91000000-0000-4000-8000-000000000008"
  | Closed_associate -> uuid "91000000-0000-4000-8000-000000000009"
  | Closed_delete -> uuid "91000000-0000-4000-8000-000000000010"
  | Class_property_add -> uuid "91000000-0000-4000-8000-000000000011"
  | Class_property_remove -> uuid "91000000-0000-4000-8000-000000000012"
;;

let mutation case context =
  let open Logseq_db_worker.Protocol in
  match case with
  | Save -> Save_block { block = uuid parent_uuid; title = "Saved by parity"; context }
  | Insert ->
    Insert_blocks
      { roots =
          [ { uuid = uuid inserted_uuid; title = "Inserted by parity"; children = [] } ]
      ; position = Relative (After (uuid sibling_uuid))
      ; context
      }
  | Move ->
    Move_blocks
      { roots = [ uuid second_child_uuid ]
      ; position = After (uuid sibling_uuid)
      ; context
      }
  | Move_up -> Move_up_down { roots = [ uuid sibling_uuid ]; direction = Up; context }
  | Indent ->
    Indent_outdent { roots = [ uuid sibling_uuid ]; direction = Indent; context }
  | Outdent ->
    Indent_outdent
      { roots = [ uuid second_child_uuid ]; direction = Direct_outdent; context }
  | Delete -> Delete_blocks { roots = [ uuid first_child_uuid ]; context }
;;

let execute_case engine case =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "cross-runtime Engine has no basis"
  in
  let context =
    Logseq_db_worker.Protocol.{ mutation_id = mutation_id case; expected_basis = basis }
  in
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version; request_id; command = Mutate (Structural (mutation case context)) }
  with
  | Succeeded
      { success = Mutation_result { status = Applied; basis_before; basis_after; _ }
      ; basis = response_basis
      ; _
      } ->
    T.require (basis_before = basis) "mutation reported the wrong basisBefore";
    T.require
      (basis_after = Int64.succ basis && response_basis = basis_after)
      "mutation did not advance basis exactly once"
  | Failed failure ->
    T.fail
      "OCaml %s failed: %s (%s)"
      (case_name case)
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
      (Logseq_db_worker.Error.message failure.error)
  | _ -> T.fail "OCaml %s did not return Applied" (case_name case)
;;

let page_mutation case context =
  let open Logseq_db_worker.Protocol in
  match case with
  | Ordinary_create ->
    Create_page
      { title = "Created by parity"
      ; kind = Create_ordinary_page { uuid = uuid created_page_uuid }
      ; context
      }
  | Journal_create ->
    Create_page
      { title = "Jan 2nd, 2024"
      ; kind =
          Create_journal_page
            { journal_day = 20240102; supplied_uuid = Some (uuid created_journal_uuid) }
      ; context
      }
  | Class_create ->
    Create_page
      { title = "Created Class"
      ; kind = Create_class_page { uuid = uuid created_class_uuid }
      ; context
      }
  | Rename -> Rename_page { page = uuid page_uuid; title = "Renamed by parity"; context }
  | Recycle_delete -> Delete_page { page = uuid page_uuid; context }
  | Restore -> Restore_recycled_page { page = uuid page_uuid; context }
  | Permanent_delete ->
    Permanently_delete_recycled_page { page = uuid page_uuid; context }
;;

let property_selector ident =
  Logseq_db_worker.Graph_types.Property_by_ident ident
;;

let property_mutation case context =
  let open Logseq_db_worker.Protocol in
  let open Logseq_db_worker.Graph_types in
  match case with
  | Property_upsert ->
    Upsert_property
      { property =
          New_property { ident = created_property; title = "Parity Created" }
      ; schema =
          { property_type = Number
          ; cardinality = One
          ; hidden = false
          ; public = true
          }
      ; context
      }
  | Property_set ->
    Set_property
      { block = uuid parent_uuid
      ; property = property_selector checkbox_property
      ; value = Checkbox_value true
      ; context
      }
  | Property_remove ->
    Remove_property
      { block = uuid parent_uuid
      ; property = property_selector checkbox_property
      ; context
      }
  | Property_batch_append ->
    Batch_set_property
      { blocks = [ uuid parent_uuid; uuid sibling_uuid ]
      ; property = property_selector many_property
      ; mode = Append (String_value "one")
      ; context
      }
  | Property_batch_replace ->
    Batch_set_property
      { blocks = [ uuid parent_uuid; uuid sibling_uuid ]
      ; property = property_selector many_property
      ; mode = Replace [ String_value "two"; String_value "three" ]
      ; context
      }
  | Property_batch_remove ->
    Batch_remove_property
      { blocks = [ uuid parent_uuid; uuid sibling_uuid ]
      ; property = property_selector many_property
      ; context
      }
  | Closed_add ->
    Manage_closed_values
      { property = property_selector default_property
      ; action =
          Add_closed_value
            { value_uuid = uuid closed_value_uuid
            ; value = Default_value "Choice"
            ; icon = None
            }
      ; context
      }
  | Closed_update ->
    Manage_closed_values
      { property = property_selector default_property
      ; action =
          Update_closed_value
            { value_uuid = uuid closed_value_uuid
            ; value = Default_value "Updated"
            ; icon = None
            }
      ; context
      }
  | Closed_associate ->
    Manage_closed_values
      { property = property_selector default_property
      ; action = Associate_closed_value { value_uuid = uuid associated_value_uuid }
      ; context
      }
  | Closed_delete ->
    Manage_closed_values
      { property = property_selector default_property
      ; action = Delete_closed_value { value_uuid = uuid closed_value_uuid }
      ; context
      }
  | Class_property_add ->
    Manage_class_property
      { class_ = uuid created_class_uuid
      ; property = property_selector checkbox_property
      ; action = Add_class_property { default_value = None }
      ; context
      }
  | Class_property_remove ->
    Manage_class_property
      { class_ = uuid created_class_uuid
      ; property = property_selector checkbox_property
      ; action = Remove_class_property
      ; context
      }
;;

let execute_page_case engine case =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "page cross-runtime Engine has no basis"
  in
  let context =
    Logseq_db_worker.Protocol.
      { mutation_id = page_mutation_id case; expected_basis = basis }
  in
  (match
     Engine.execute
       engine
       Logseq_db_worker.Protocol.
         { api_version; request_id; command = Mutate (Page (page_mutation case context)) }
   with
   | Succeeded
       { success = Mutation_result { status = Applied; basis_before; basis_after; _ }
       ; basis = response_basis
       ; _
       } ->
     T.require (basis_before = basis) "page mutation reported the wrong basisBefore";
     T.require
       (basis_after = Int64.succ basis && response_basis = basis_after)
       "page mutation did not advance basis exactly once"
   | Failed failure ->
     T.fail
       "OCaml page %s failed: %s (%s)"
       (page_case_name case)
       (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
       (Logseq_db_worker.Error.message failure.error)
   | _ -> T.fail "OCaml page %s did not return Applied" (page_case_name case));
  match case with
  | Recycle_delete ->
    (match
       Engine.execute
         engine
         Logseq_db_worker.Protocol.
           { api_version
           ; request_id
           ; command = Read (Get_page { page = Page_by_uuid (uuid page_uuid) })
           }
     with
     | Succeeded { success = Page_result page; _ } ->
       T.require page.recycled "page is not recycled immediately after OCaml delete"
     | _ -> T.fail "deleted page cannot be read immediately after OCaml delete")
  | Ordinary_create | Journal_create | Class_create | Rename | Restore | Permanent_delete
    -> ()
;;

let execute_property_case engine case =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "property cross-runtime Engine has no basis"
  in
  let context =
    Logseq_db_worker.Protocol.
      { mutation_id = property_mutation_id case; expected_basis = basis }
  in
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version
        ; request_id
        ; command = Mutate (Property (property_mutation case context))
        }
  with
  | Succeeded
      { success = Mutation_result { status = Applied; basis_before; basis_after; _ }
      ; basis = response_basis
      ; _
      } ->
    T.require (basis_before = basis) "property mutation reported the wrong basisBefore";
    T.require
      (basis_after = Int64.succ basis && response_basis = basis_after)
      "property mutation did not advance basis exactly once"
  | Failed failure ->
    T.fail
      "OCaml property %s failed: %s (%s)"
      (property_case_name case)
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
      (Logseq_db_worker.Error.message failure.error)
  | _ -> T.fail "OCaml property %s did not return Applied" (property_case_name case)
;;

let require_block_title engine block expected =
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version; request_id; command = Read (Get_block { block = uuid block }) }
  with
  | Succeeded { success = Block_result block; _ } ->
    T.require (String.equal block.title expected) "reopened block has the wrong title"
  | _ -> T.fail "reopened block is unavailable"
;;

let require_page_title engine page expected =
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version
        ; request_id
        ; command = Read (Get_page { page = Page_by_uuid (uuid page) })
        }
  with
  | Succeeded { success = Page_result page; _ } ->
    T.require (String.equal page.title expected) "reopened page has the wrong title"
  | _ -> T.fail "reopened page is unavailable"
;;

let require_page_recycled engine page =
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version
        ; request_id
        ; command = Read (Get_page { page = Page_by_uuid (uuid page) })
        }
  with
  | Succeeded { success = Page_result page; _ } ->
    T.require page.recycled "reopened page is not recycled"
  | _ -> T.fail "reopened recycled page is unavailable"
;;

let structural_parity options case =
  with_temp_directory (fun directory ->
    let base_database = Filename.concat directory "base.sqlite" in
    let base_projection = Filename.concat directory "base.json" in
    oracle_structural
      options
      ~case:"base"
      ~database_output:base_database
      ~projection_output:base_projection
      ();
    let logseq_database = Filename.concat directory "logseq.sqlite" in
    let logseq_projection = Filename.concat directory "logseq.json" in
    oracle_structural
      options
      ~case:(case_name case)
      ~database_input:base_database
      ~database_output:logseq_database
      ~projection_output:logseq_projection
      ();
    let ocaml_database = Filename.concat directory "ocaml.sqlite" in
    copy_file base_database ocaml_database;
    with_engine_for_database ocaml_database (fun engine _resolved ->
      execute_case engine case);
    let ocaml_projection = Filename.concat directory "ocaml.json" in
    let reopened_database = Filename.concat directory "ocaml-reopened.sqlite" in
    oracle_structural
      options
      ~case:"inspect"
      ~database_input:ocaml_database
      ~database_output:reopened_database
      ~projection_output:ocaml_projection
      ();
    compare_projections logseq_projection ocaml_projection)
;;

let logseq_write_continues_in_ocaml options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "logseq.sqlite" in
    oracle_structural
      options
      ~case:"save"
      ~database_output:database
      ~projection_output:(Filename.concat directory "logseq.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      require_block_title engine parent_uuid "Saved by parity";
      execute_case engine Insert))
;;

let ocaml_write_continues_in_logseq options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "base.sqlite" in
    oracle_structural
      options
      ~case:"base"
      ~database_output:database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    with_engine_for_database database (fun engine _resolved -> execute_case engine Save);
    oracle_structural
      options
      ~case:"continue"
      ~database_input:database
      ~database_output:(Filename.concat directory "continued.sqlite")
      ~projection_output:(Filename.concat directory "continued.json")
      ();
    let continued = T.read_json (Filename.concat directory "continued.json") in
    let projection = Yojson.Safe.Util.(continued |> member "projection" |> to_list) in
    let has_continuation =
      List.exists
        (fun entity ->
           Yojson.Safe.Util.(entity |> member "block/uuid" |> to_string_option)
           = Some continuation_uuid)
        projection
    in
    T.require has_continuation "pinned Logseq did not persist its continuation mutation")
;;

let page_base_case = function
  | Restore | Permanent_delete -> "recycled-base"
  | Ordinary_create | Journal_create | Class_create | Rename | Recycle_delete -> "base"
;;

let page_parity options case =
  with_temp_directory (fun directory ->
    let base_database = Filename.concat directory "base.sqlite" in
    oracle_page
      options
      ~case:(page_base_case case)
      ~database_output:base_database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    let logseq_database = Filename.concat directory "logseq.sqlite" in
    let logseq_projection = Filename.concat directory "logseq.json" in
    oracle_page
      options
      ~case:(page_case_name case)
      ~database_input:base_database
      ~database_output:logseq_database
      ~projection_output:logseq_projection
      ();
    let ocaml_database = Filename.concat directory "ocaml.sqlite" in
    copy_file base_database ocaml_database;
    with_engine_for_database ocaml_database (fun engine _resolved ->
      execute_page_case engine case);
    (match case with
     | Recycle_delete ->
       with_engine_for_database ocaml_database (fun engine _resolved ->
         require_page_recycled engine page_uuid)
     | Ordinary_create
     | Journal_create
     | Class_create
     | Rename
     | Restore
     | Permanent_delete -> ());
    let ocaml_projection = Filename.concat directory "ocaml.json" in
    oracle_page
      options
      ~case:"inspect"
      ~database_input:ocaml_database
      ~database_output:(Filename.concat directory "ocaml-reopened.sqlite")
      ~projection_output:ocaml_projection
      ();
    compare_projections logseq_projection ocaml_projection)
;;

let logseq_page_write_continues_in_ocaml options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "logseq.sqlite" in
    oracle_page
      options
      ~case:"rename"
      ~database_output:database
      ~projection_output:(Filename.concat directory "logseq.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      require_page_title engine page_uuid "Renamed by parity";
      execute_page_case engine Ordinary_create))
;;

let ocaml_page_write_continues_in_logseq options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "base.sqlite" in
    oracle_page
      options
      ~case:"base"
      ~database_output:database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      execute_page_case engine Rename);
    let projection_path = Filename.concat directory "continued.json" in
    oracle_page
      options
      ~case:"continue"
      ~database_input:database
      ~database_output:(Filename.concat directory "continued.sqlite")
      ~projection_output:projection_path
      ();
    let projection =
      Yojson.Safe.Util.(T.read_json projection_path |> member "projection" |> to_list)
    in
    let has_continuation =
      List.exists
        (fun entity ->
           Yojson.Safe.Util.(entity |> member "block/uuid" |> to_string_option)
           = Some page_continuation_uuid)
        projection
    in
    T.require has_continuation "pinned Logseq did not persist its page continuation")
;;

let expect_page_rejection engine ~mutation_id mutation expected_code =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "page rejection Engine has no basis"
  in
  let context = Logseq_db_worker.Protocol.{ mutation_id; expected_basis = basis } in
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version; request_id; command = Mutate (Page (mutation context)) }
  with
  | Failed failure ->
    T.require
      (Logseq_db_worker.Error.code failure.error = expected_code)
      "page restriction returned the wrong typed error"
  | Succeeded _ -> T.fail "page restriction unexpectedly mutated the graph"
;;

let page_worker_restrictions options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "base.sqlite" in
    oracle_page
      options
      ~case:"base"
      ~database_output:database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      let open Logseq_db_worker.Protocol in
      expect_page_rejection
        engine
        ~mutation_id:(uuid "f0000000-0000-4000-8000-000000000001")
        (fun context ->
           Create_page
             { title = "Implicit/Namespace"
             ; kind = Create_ordinary_page { uuid = uuid created_page_uuid }
             ; context
             })
        Logseq_db_worker.Error.Unsupported_semantics;
      expect_page_rejection
        engine
        ~mutation_id:(uuid "f0000000-0000-4000-8000-000000000002")
        (fun context -> Restore_recycled_page { page = uuid page_uuid; context })
        Logseq_db_worker.Error.Not_found;
      expect_page_rejection
        engine
        ~mutation_id:(uuid "f0000000-0000-4000-8000-000000000003")
        (fun context ->
           Permanently_delete_recycled_page { page = uuid page_uuid; context })
        Logseq_db_worker.Error.Not_found;
      expect_page_rejection
        engine
        ~mutation_id:(uuid "f0000000-0000-4000-8000-000000000004")
        (fun context ->
           Create_page
             { title = "Jan 2nd, 2024"
             ; kind =
                 Create_journal_page
                   { journal_day = 20240102
                   ; supplied_uuid = Some (uuid created_page_uuid)
                   }
             ; context
             })
        Logseq_db_worker.Error.Conflict))
;;

let property_base_case = function
  | Property_remove -> "set-base"
  | Property_batch_replace | Property_batch_remove -> "many-base"
  | Closed_update | Closed_delete -> "closed-base"
  | Class_property_remove -> "class-base"
  | Property_upsert
  | Property_set
  | Property_batch_append
  | Closed_add
  | Class_property_add -> "base"
  | Closed_associate -> "associated-base"
;;

let property_parity options case =
  with_temp_directory (fun directory ->
    let base_database = Filename.concat directory "base.sqlite" in
    oracle_property
      options
      ~case:(property_base_case case)
      ~database_output:base_database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    let logseq_projection = Filename.concat directory "logseq.json" in
    oracle_property
      options
      ~case:(property_case_name case)
      ~database_output:(Filename.concat directory "logseq.sqlite")
      ~projection_output:logseq_projection
      ();
    let ocaml_database = Filename.concat directory "ocaml.sqlite" in
    copy_file base_database ocaml_database;
    with_engine_for_database ocaml_database (fun engine _resolved ->
      execute_property_case engine case);
    let ocaml_projection = Filename.concat directory "ocaml.json" in
    oracle_property
      options
      ~case:"inspect"
      ~database_input:ocaml_database
      ~database_output:(Filename.concat directory "ocaml-reopened.sqlite")
      ~projection_output:ocaml_projection
      ();
    compare_projections logseq_projection ocaml_projection)
;;

let logseq_property_write_continues_in_ocaml options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "logseq.sqlite" in
    oracle_property
      options
      ~case:"set"
      ~database_output:database
      ~projection_output:(Filename.concat directory "logseq.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      execute_property_case engine Property_remove))
;;

let ocaml_property_write_continues_in_logseq options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "base.sqlite" in
    oracle_property
      options
      ~case:"base"
      ~database_output:database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      execute_property_case engine Property_set);
    oracle_property
      options
      ~case:"continue"
      ~database_input:database
      ~database_output:(Filename.concat directory "continued.sqlite")
      ~projection_output:(Filename.concat directory "continued.json")
      ())
;;

let expect_property_rejection engine ~mutation_id mutation expected_code =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> T.fail "property rejection Engine has no basis"
  in
  let context = Logseq_db_worker.Protocol.{ mutation_id; expected_basis = basis } in
  match
    Engine.execute
      engine
      Logseq_db_worker.Protocol.
        { api_version; request_id; command = Mutate (Property (mutation context)) }
  with
  | Failed failure ->
    T.require
      (Logseq_db_worker.Error.code failure.error = expected_code)
      "property restriction returned the wrong typed error"
  | Succeeded _ -> T.fail "property restriction unexpectedly mutated the graph"
;;

let property_worker_restrictions options =
  with_temp_directory (fun directory ->
    let database = Filename.concat directory "base.sqlite" in
    oracle_property
      options
      ~case:"base"
      ~database_output:database
      ~projection_output:(Filename.concat directory "base.json")
      ();
    with_engine_for_database database (fun engine _resolved ->
      let open Logseq_db_worker.Protocol in
      let open Logseq_db_worker.Graph_types in
      expect_property_rejection
        engine
        ~mutation_id:(uuid "92000000-0000-4000-8000-000000000001")
        (fun context ->
           Upsert_property
             { property =
                 New_property
                   { ident = "user.property/internal"; title = "Internal" }
             ; schema =
                 { property_type = Keyword
                 ; cardinality = One
                 ; hidden = false
                 ; public = true
                 }
             ; context
             })
        Logseq_db_worker.Error.Unsupported_semantics;
      expect_property_rejection
        engine
        ~mutation_id:(uuid "92000000-0000-4000-8000-000000000002")
        (fun context ->
           Batch_set_property
             { blocks =
                 [ uuid parent_uuid
                 ; uuid "92999999-0000-4000-8000-000000000099"
                 ]
             ; property = property_selector many_property
             ; mode = Append (String_value "missing")
             ; context
             })
        Logseq_db_worker.Error.Not_found))
;;

let comparer_normalization_boundary () =
  with_temp_directory (fun directory ->
    let write name value =
      let path = Filename.concat directory name in
      Yojson.Safe.to_file path value;
      path
    in
    let expected =
      write
        "expected.json"
        (`Assoc
            [ ( "projection"
              , `List
                  [ `Assoc
                      [ "block/uuid", `String parent_uuid
                      ; "block/title", `String "same"
                      ; "block/created-at", `String "$normalizedEpochMs"
                      ; "block/tx-id", `String "$normalizedTransactionId"
                      ]
                  ] )
            ])
    in
    let permitted =
      write
        "permitted.json"
        (`Assoc
            [ ( "projection"
              , `List
                  [ `Assoc
                      [ "block/tx-id", `String "$normalizedTransactionId"
                      ; "block/created-at", `String "$normalizedEpochMs"
                      ; "block/title", `String "same"
                      ; "block/uuid", `String parent_uuid
                      ]
                  ] )
            ])
    in
    compare_projections expected permitted;
    let divergent =
      write
        "divergent.json"
        (`Assoc
            [ ( "projection"
              , `List
                  [ `Assoc
                      [ "block/uuid", `String parent_uuid
                      ; "block/title", `String "different"
                      ; "block/created-at", `String "$normalizedEpochMs"
                      ; "block/tx-id", `String "$normalizedTransactionId"
                      ]
                  ] )
            ])
    in
    let rejected =
      try
        compare_projections expected divergent;
        false
      with
      | Failure _ -> true
    in
    T.require rejected "canonical comparer accepted a semantic title difference")
;;

let require_clean_interop_commit options =
  T.require
    (String.length options.expected_interop_commit = 40)
    "--expected-interop-commit must be the full coordinated Logseq commit";
  let actual =
    command_output "git" [ "-C"; options.interop_repo; "rev-parse"; "HEAD" ] |> trim
  in
  T.require
    (String.equal actual options.expected_interop_commit)
    "the coordinated Logseq worktree is at the wrong commit";
  let status =
    command_output
      "git"
      [ "-C"; options.interop_repo; "status"; "--porcelain=v1"; "--untracked-files=all" ]
    |> trim
  in
  T.require (String.equal status "") "the coordinated Logseq worktree is not clean"
;;

let wait_for_lock_rejection child server_list =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    match poll_child child with
    | Some (Unix.WEXITED code) ->
      T.require
        (code <> 0)
        "the second Logseq writer exited successfully while OCaml owned the graph"
    | Some (WSIGNALED signal) ->
      T.fail "the second Logseq writer was killed by signal %d" signal
    | Some (WSTOPPED signal) ->
      T.fail "the second Logseq writer stopped with signal %d" signal
    | None when Option.is_some (parse_server_port server_list) ->
      T.fail "the second Logseq writer became Ready while OCaml owned the graph"
    | None when Unix.gettimeofday () >= deadline ->
      T.fail "the second Logseq writer did not reject the live OCaml owner"
    | None ->
      Unix.sleepf 0.05;
      loop ()
  in
  loop ()
;;

let marker_generations graph_dir =
  match
    T.read_json (Filename.concat graph_dir ".logseq-db-worker.derived-sidecars.json")
  with
  | `Assoc fields ->
    let generation name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Some value
      | Some `Null -> None
      | _ -> T.fail "invalid %s in the derived-sidecar marker" name
    in
    T.require
      (List.assoc_opt "formatVersion" fields = Some (`Int 1))
      "derived-sidecar marker format changed";
    generation "ftsRequiredGeneration", generation "vectorRequiredGeneration"
  | _ -> T.fail "derived-sidecar marker is not an object"
;;

let in_phase phase f =
  try f () with
  | exn -> T.fail "%s: %s" phase (Printexc.to_string exn)
;;

let native_ownership_acceptance options =
  require_clean_interop_commit options;
  let node_script = Filename.concat options.interop_repo "static/db-worker-node.js" in
  T.require
    (Sys.file_exists node_script)
    "the coordinated db-worker-node build is missing; run pnpm db-worker-node:compile";
  with_temp_directory (fun directory ->
    let root_dir = Filename.concat directory "runtime" in
    let graphs_dir = Filename.concat root_dir "graphs" in
    let graph_name = "native_ownership" in
    let repo = "logseq_db_" ^ graph_name in
    let graph_dir = Filename.concat graphs_dir graph_name in
    Unix.mkdir root_dir 0o700;
    Unix.mkdir graphs_dir 0o700;
    Unix.mkdir graph_dir 0o700;
    let database = Filename.concat directory "base.sqlite" in
    in_phase "create pinned base database" (fun () ->
      oracle_structural
        options
        ~case:"base"
        ~database_output:database
        ~projection_output:(Filename.concat directory "base.json")
        ());
    copy_file database (Filename.concat graph_dir "db.sqlite");
    let server_list = Filename.concat root_dir "server-list" in
    let daemon_arguments =
      [ node_script
      ; "--root-dir"
      ; root_dir
      ; "--repo"
      ; repo
      ; "--owner-source"
      ; "unknown"
      ; "--log-level"
      ; "error"
      ]
    in
    let engine =
      in_phase "open native graph in OCaml" (fun () ->
        match Engine.open_ ~dependencies (native_config directory graph_dir) with
        | Ok engine -> engine
        | Error error ->
          T.fail
            "unable to open native graph in OCaml: %s (%s)"
            (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code error))
            (Logseq_db_worker.Error.message error))
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close engine))
      (fun () ->
         in_phase "commit native OCaml mutation" (fun () -> execute_case engine Save);
         let contender =
           in_phase "spawn competing Logseq writer" (fun () ->
             spawn_process "node" daemon_arguments)
         in
         Fun.protect
           ~finally:(fun () -> cleanup_child contender)
           (fun () -> wait_for_lock_rejection contender server_list);
         match Engine.close engine with
         | Ok () -> ()
         | Error message -> T.fail "native Engine close failed: %s" message);
    let fts_generation, vector_generation =
      in_phase "read native invalidation marker" (fun () -> marker_generations graph_dir)
    in
    T.require (Option.is_some fts_generation) "native mutation did not invalidate FTS";
    T.require
      (Option.is_some vector_generation)
      "native mutation did not invalidate vector";
    let daemon =
      in_phase "spawn Logseq reopen" (fun () -> spawn_process "node" daemon_arguments)
    in
    Fun.protect
      ~finally:(fun () -> cleanup_child daemon)
      (fun () ->
         let port =
           in_phase "wait for Logseq reopen" (fun () ->
             wait_for_server daemon server_list)
         in
         let consumed_fts, retained_vector =
           in_phase "read consumed invalidation marker" (fun () ->
             marker_generations graph_dir)
         in
         T.require
           (Option.is_none consumed_fts)
           "the vector-incapable Logseq reopen did not rebuild and clear FTS";
         T.require
           (retained_vector = vector_generation)
           "the vector-incapable Logseq reopen consumed the later vector rebuild \
            requirement";
         in_phase "shut down Logseq reopen" (fun () ->
           ignore
             (command_output
                "/usr/bin/curl"
                [ "--fail"
                ; "--silent"
                ; "--show-error"
                ; "--request"
                ; "POST"
                ; Printf.sprintf "http://127.0.0.1:%d/v1/shutdown" port
                ]));
         match wait_child daemon with
         | Unix.WEXITED 0 -> ()
         | WEXITED code -> T.fail "interop daemon shutdown exited %d" code
         | WSIGNALED signal -> T.fail "interop daemon shutdown was killed by %d" signal
         | WSTOPPED signal -> T.fail "interop daemon shutdown stopped by %d" signal);
    T.require
      (not (Sys.file_exists (Filename.concat graph_dir "db-worker.lock")))
      "Logseq did not release the coordinated owner sentinel";
    let reopened =
      in_phase "reacquire graph in OCaml" (fun () ->
        match Engine.open_ ~dependencies (native_config directory graph_dir) with
        | Ok engine -> engine
        | Error error ->
          T.fail
            "OCaml could not reacquire the graph after Logseq release: %s"
            (Logseq_db_worker.Error.message error))
    in
    Fun.protect
      ~finally:(fun () -> ignore (Engine.close reopened))
      (fun () -> require_block_title reopened parent_uuid "Saved by parity"))
;;

let () =
  let options = options () in
  match options.slice with
  | "structural" ->
    T.run
      "cross runtime"
      [ T.case "oracle metadata is pinned" oracle_metadata
      ; T.case
          "canonical comparer permits only declared normalization"
          comparer_normalization_boundary
      ; T.case "Save_block matches canonical Logseq projection" (fun () ->
          structural_parity options Save)
      ; T.case "Insert_blocks matches canonical Logseq projection" (fun () ->
          structural_parity options Insert)
      ; T.case "Move_blocks matches canonical Logseq projection" (fun () ->
          structural_parity options Move)
      ; T.case "Move_up_down matches canonical Logseq projection" (fun () ->
          structural_parity options Move_up)
      ; T.case "Indent matches canonical Logseq projection" (fun () ->
          structural_parity options Indent)
      ; T.case "Direct_outdent matches canonical Logseq projection" (fun () ->
          structural_parity options Outdent)
      ; T.case "Delete_blocks matches canonical Logseq projection" (fun () ->
          structural_parity options Delete)
      ; T.case "Logseq structural write reopens and mutates in OCaml" (fun () ->
          logseq_write_continues_in_ocaml options)
      ; T.case "OCaml structural write reopens and mutates in pinned Logseq" (fun () ->
          ocaml_write_continues_in_logseq options)
      ]
  | "native-ownership" ->
    T.run
      "native ownership cross runtime"
      [ T.case "clean coordinated Logseq owns and releases the native graph" (fun () ->
          native_ownership_acceptance options)
      ]
  | "pages" ->
    T.run
      "page cross runtime"
      [ T.case "ordinary page creation matches canonical Logseq projection" (fun () ->
          page_parity options Ordinary_create)
      ; T.case "journal page creation matches canonical Logseq projection" (fun () ->
          page_parity options Journal_create)
      ; T.case "class page creation matches canonical Logseq projection" (fun () ->
          page_parity options Class_create)
      ; T.case "page rename matches canonical Logseq projection" (fun () ->
          page_parity options Rename)
      ; T.case "page recycle delete matches canonical Logseq projection" (fun () ->
          page_parity options Recycle_delete)
      ; T.case "recycled page restore matches canonical Logseq projection" (fun () ->
          page_parity options Restore)
      ; T.case
          "recycled page permanent delete matches canonical Logseq projection"
          (fun () -> page_parity options Permanent_delete)
      ; T.case "Logseq page write reopens and mutates in OCaml" (fun () ->
          logseq_page_write_continues_in_ocaml options)
      ; T.case "OCaml page write reopens and mutates in pinned Logseq" (fun () ->
          ocaml_page_write_continues_in_logseq options)
      ; T.case "page pre-stage restrictions are typed Worker failures" (fun () ->
          page_worker_restrictions options)
      ]
  | "properties" ->
    T.run
      "property cross runtime"
      [ T.case "property upsert matches canonical Logseq projection" (fun () ->
          property_parity options Property_upsert)
      ; T.case "property set matches canonical Logseq projection" (fun () ->
          property_parity options Property_set)
      ; T.case "property remove matches canonical Logseq projection" (fun () ->
          property_parity options Property_remove)
      ; T.case "property batch append matches canonical Logseq projection" (fun () ->
          property_parity options Property_batch_append)
      ; T.case "property batch replace matches canonical Logseq projection" (fun () ->
          property_parity options Property_batch_replace)
      ; T.case "property batch remove matches canonical Logseq projection" (fun () ->
          property_parity options Property_batch_remove)
      ; T.case "closed value add matches canonical Logseq projection" (fun () ->
          property_parity options Closed_add)
      ; T.case "closed value update matches canonical Logseq projection" (fun () ->
          property_parity options Closed_update)
      ; T.case "closed value association matches canonical Logseq projection" (fun () ->
          property_parity options Closed_associate)
      ; T.case "closed value deletion matches canonical Logseq projection" (fun () ->
          property_parity options Closed_delete)
      ; T.case "class property add matches canonical Logseq projection" (fun () ->
          property_parity options Class_property_add)
      ; T.case "class property remove matches canonical Logseq projection" (fun () ->
          property_parity options Class_property_remove)
      ; T.case "Logseq property write reopens and mutates in OCaml" (fun () ->
          logseq_property_write_continues_in_ocaml options)
      ; T.case "OCaml property write reopens and mutates in pinned Logseq" (fun () ->
          ocaml_property_write_continues_in_logseq options)
      ; T.case "property pre-stage restrictions are typed Worker failures" (fun () ->
          property_worker_restrictions options)
      ]
  | slice -> T.fail "unknown cross-runtime slice: %s" slice
;;

module Protocol = Logseq_db_worker.Protocol
module Config = Logseq_db_worker.Config
module Engine = Logseq_db_worker.Engine
module Snapshot = Logseq_db_worker__Snapshot
module Graph_locator = Logseq_db_worker__Graph_locator

type session_error =
  | Local_decode_error of string
  | Fatal_lifecycle_error of string

type session =
  | Ready of Engine.t
  | Open_failed of Logseq_db_worker.Error.t

let bounded_message message =
  let maximum = 512 in
  if String.length message <= maximum then message else String.sub message 0 maximum
;;

let snapshot_error = function
  | Snapshot.Invalid_catalog_root -> "invalid snapshot catalog root"
  | Invalid_inbox_entry -> "invalid snapshot inbox entry"
  | Source_missing -> "snapshot source is missing"
  | Manifest_mismatch -> "snapshot manifest does not match its database"
  | Token_unknown -> "snapshot token is unknown"
  | Path_escape -> "snapshot path escapes its catalog"
  | Symlink_rejected -> "snapshot path contains a symbolic link"
  | Hard_link_rejected -> "snapshot database contains a hard link"
  | Publish_failed _ -> "snapshot publication failed"
;;

let graph_locator_error = function
  | Graph_locator.Invalid_graph_name _ -> "invalid graph name"
  | Invalid_utf8 -> "graph name is not valid UTF-8"
  | Path_escape -> "graph path escapes the platform graph root"
  | Symlink_escape -> "graph path escapes through a symbolic link"
  | Basename_mismatch -> "graph directory basename does not match graph name"
  | Graph_directory_missing -> "graph directory is missing"
  | Database_missing -> "graph db.sqlite is missing"
;;

let open_session ~dependencies config =
  match Engine.open_ ~dependencies config with
  | Ok engine -> Ready engine
  | Error error -> Open_failed error
;;

let execute session request =
  match session with
  | Ready engine -> Engine.execute engine request
  | Open_failed error ->
    Protocol.failed ~request_id:request.Protocol.request_id ~phase:Open ~basis:None error
;;

let close_session = function
  | Open_failed _ -> Ok ()
  | Ready engine -> Engine.close engine
;;

let protect_session session operation =
  let result =
    try operation () with
    | Engine.Fatal_storage_error message -> Error (Fatal_lifecycle_error message)
    | Sys_error message -> Error (Fatal_lifecycle_error (bounded_message message))
  in
  match close_session session with
  | Error message -> Error (Fatal_lifecycle_error (bounded_message message))
  | Ok () -> result
;;

let execute_once_with ~dependencies ~after_execute config request =
  let session = open_session ~dependencies config in
  protect_session session (fun () ->
    let response = execute session request in
    after_execute ();
    Ok response)
;;

let execute_once ~dependencies config request =
  execute_once_with ~dependencies ~after_execute:(fun () -> ()) config request
;;

let decode_request_line line =
  if String.length line > Protocol.maximum_request_bytes
  then Error (Local_decode_error "request exceeds the protocol byte budget")
  else (
    try
      match Protocol.request_of_yojson (Yojson.Safe.from_string line) with
      | Ok request -> Ok request
      | Error error ->
        Error
          (Local_decode_error (Logseq_db_worker.Error.message error |> bounded_message))
    with
    | Yojson.Json_error message -> Error (Local_decode_error (bounded_message message)))
;;

let run_ndjson_lines ~dependencies config lines =
  let session = open_session ~dependencies config in
  protect_session session (fun () ->
    let rec loop output = function
      | [] -> Ok (List.rev output)
      | line :: rest ->
        (match decode_request_line line with
         | Error _ as error -> error
         | Ok request ->
           let response = execute session request in
           loop (Cli_output.response_line response :: output) rest)
    in
    loop [] lines)
;;

let create_snapshot ~application_support_directory ~source_graph_dir =
  match Snapshot.create_catalog ~application_support_directory with
  | Error error -> Error (snapshot_error error)
  | Ok catalog ->
    Result.map_error snapshot_error (Snapshot.create catalog ~source_graph_dir)
;;

let import_snapshot ~application_support_directory ~inbox_entry =
  match Snapshot.create_catalog ~application_support_directory with
  | Error error -> Error (snapshot_error error)
  | Ok catalog -> Result.map_error snapshot_error (Snapshot.import catalog ~inbox_entry)
;;

let resolve_desktop_target ~home_directory ~graph_name =
  match Graph_locator.resolve (Desktop { home_directory }) ~graph_name with
  | Error error -> Error (graph_locator_error error)
  | Ok resolved ->
    Ok
      (Config.Native_local_graph
         { graph_name = resolved.graph_name; graph_dir = resolved.graph_dir })
;;

let random_bytes length =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel length |> Bytes.of_string)
;;

let random_uuid () =
  let bytes = random_bytes 16 in
  Bytes.set bytes 6 (Char.chr (Char.code (Bytes.get bytes 6) land 0x0f lor 0x40));
  Bytes.set bytes 8 (Char.chr (Char.code (Bytes.get bytes 8) land 0x3f lor 0x80));
  let buffer = Buffer.create 36 in
  Bytes.iteri
    (fun index byte ->
       if List.mem index [ 4; 6; 8; 10 ] then Buffer.add_char buffer '-';
       Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  match Logseq_db_worker.Graph_types.Uuid.of_string (Buffer.contents buffer) with
  | Ok uuid -> uuid
  | Error message -> failwith message
;;

let production_dependencies () =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> Unix.gettimeofday () *. 1_000. |> Int64.of_float)
        ; monotonic_ns = Mtime_clock.elapsed_ns
        }
    ; cursor_authentication_key = random_bytes 32
    ; crypto = Logseq_db_worker.Sync_e2ee.unavailable_crypto
    ; unlock_graph_key =
        (fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
          Error "crypto unavailable")
    }
;;

let rec ensure_directory path =
  if Sys.file_exists path
  then
    if (Unix.stat path).Unix.st_kind = Unix.S_DIR
    then Ok (Unix.realpath path)
    else Error "application-support path is not a directory"
  else (
    let parent = Filename.dirname path in
    if String.equal parent path
    then Error "application-support directory has no existing root"
    else (
      match ensure_directory parent with
      | Error _ as error -> error
      | Ok _ ->
        (try
           Unix.mkdir path 0o700;
           Ok (Unix.realpath path)
         with
         | Unix.Unix_error _ -> Error "unable to create application-support directory")))
;;

let default_application_support () =
  match Sys.getenv_opt "HOME" with
  | None -> ""
  | Some home -> Filename.concat home "Library/Application Support/logseq-db-worker"
;;

let target_of_options snapshot_token graph_name inbox_entry =
  match snapshot_token, graph_name, inbox_entry with
  | Some token, None, None ->
    Result.map
      (fun token -> Config.Snapshot { token })
      (Logseq_db_worker.Graph_types.Uuid.of_string token)
  | None, Some graph_name, None ->
    (match Sys.getenv_opt "HOME" with
     | None -> Error "HOME is required to resolve ~/logseq/<graph-name>"
     | Some home_directory ->
       (match Graph_locator.resolve (Desktop { home_directory }) ~graph_name with
        | Ok resolved ->
          Ok
            (Config.Native_local_graph
               { graph_name = resolved.graph_name; graph_dir = resolved.graph_dir })
        | Error Graph_locator.Graph_directory_missing ->
          let root = Filename.concat home_directory "logseq" in
          (try
             let canonical_root = Unix.realpath root in
             Ok
               (Config.Native_local_graph
                  { graph_name; graph_dir = Filename.concat canonical_root graph_name })
           with
           | Unix.Unix_error _ -> Error "Desktop ~/logseq root cannot be resolved")
        | Error Graph_locator.Path_escape
          when not (Sys.file_exists (Filename.concat home_directory "logseq")) ->
          (try
             let canonical_home = Unix.realpath home_directory in
             Ok
               (Config.Native_local_graph
                  { graph_name
                  ; graph_dir =
                      Filename.concat (Filename.concat canonical_home "logseq") graph_name
                  })
           with
           | Unix.Unix_error _ -> Error "HOME cannot be resolved")
        | Error error -> Error (graph_locator_error error)))
  | None, None, Some inbox_entry -> Ok (Config.Import_snapshot { inbox_entry })
  | _ ->
    Error "select exactly one of --snapshot-token, --graph-name, or --import-inbox-entry"
;;

let build_config application_support_directory snapshot_token graph_name inbox_entry =
  match ensure_directory application_support_directory with
  | Error _ as error -> error
  | Ok application_support_directory ->
    (match target_of_options snapshot_token graph_name inbox_entry with
     | Error _ as error -> error
     | Ok target ->
       Config.create
         ~application_support_directory
         ~target
         ~compatibility_profile:Logseq_65_33_or_newer
         ~response_budget_bytes:Protocol.maximum_response_bytes
         ~default_page_size:Protocol.default_page_size)
;;

let read_file_bounded path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         let length = in_channel_length channel in
         if length > Protocol.maximum_request_bytes
         then Error "request exceeds the protocol byte budget"
         else Ok (really_input_string channel length))
  with
  | Sys_error _ -> Error "unable to read request file"
;;

let request_from_file path =
  match read_file_bounded path with
  | Error _ as error -> error
  | Ok contents ->
    (match decode_request_line contents with
     | Ok request -> Ok request
     | Error (Local_decode_error message | Fatal_lifecycle_error message) -> Error message)
;;

let report_error classification message =
  prerr_endline (bounded_message message);
  Cli_output.exit_code classification
;;

let run_request config request =
  match execute_once ~dependencies:(production_dependencies ()) config request with
  | Error (Local_decode_error message) -> report_error Local_error message
  | Error (Fatal_lifecycle_error message) -> report_error Fatal_error message
  | Ok response ->
    print_endline (Cli_output.response_line response);
    response |> Cli_output.classify_response |> Cli_output.exit_code
;;

type bounded_line =
  | End_of_input
  | Line of string
  | Line_too_long

let read_bounded_line channel =
  let buffer = Buffer.create 256 in
  let rec loop () =
    match input_char channel with
    | '\n' -> Line (Buffer.contents buffer)
    | '\r' ->
      (match input_char channel with
       | '\n' -> Line (Buffer.contents buffer)
       | character ->
         Buffer.add_char buffer '\r';
         Buffer.add_char buffer character;
         loop ()
       | exception End_of_file -> Line (Buffer.contents buffer))
    | character ->
      Buffer.add_char buffer character;
      if Buffer.length buffer > Protocol.maximum_request_bytes
      then Line_too_long
      else loop ()
    | exception End_of_file ->
      if Buffer.length buffer = 0 then End_of_input else Line (Buffer.contents buffer)
  in
  loop ()
;;

let run_ndjson_channels config =
  let session = open_session ~dependencies:(production_dependencies ()) config in
  let result =
    protect_session session (fun () ->
      let rec loop () =
        match read_bounded_line stdin with
        | End_of_input -> Ok ()
        | Line_too_long ->
          Error (Local_decode_error "request exceeds the protocol byte budget")
        | Line line ->
          (match decode_request_line line with
           | Error _ as error -> error
           | Ok request ->
             print_endline (execute session request |> Cli_output.response_line);
             flush stdout;
             loop ())
      in
      loop ())
  in
  match result with
  | Ok () -> Cli_output.exit_code Success
  | Error (Local_decode_error message) -> report_error Local_error message
  | Error (Fatal_lifecycle_error message) -> report_error Fatal_error message
;;

open Cmdliner

let support_term =
  let doc = "Application-support directory used for the snapshot catalog." in
  Arg.(
    value
    & opt string (default_application_support ())
    & info [ "application-support-directory" ] ~docv:"DIR" ~doc)
;;

let snapshot_token_term =
  Arg.(value & opt (some string) None & info [ "snapshot-token" ] ~docv:"TOKEN")
;;

let graph_name_term =
  Arg.(value & opt (some string) None & info [ "graph-name" ] ~docv:"NAME")
;;

let inbox_target_term =
  Arg.(value & opt (some string) None & info [ "import-inbox-entry" ] ~docv:"ENTRY")
;;

let with_config action = function
  | Error message -> report_error Local_error message
  | Ok config -> action config
;;

let save_block_request request =
  match request.Protocol.command with
  | Mutate (Structural (Save_block _)) -> Ok ()
  | _ -> Error "block save requires a structural saveBlock protocol request"
;;

let command_path_term = Arg.(value & pos_all string [] & info [] ~docv:"COMMAND")

let optional_uuid_term =
  Arg.(value & opt (some string) None & info [ "uuid" ] ~docv:"UUID")
;;

let optional_request_path_term =
  Arg.(value & opt (some file) None & info [ "request" ] ~docv:"FILE")
;;

let limit_term =
  Arg.(value & opt int Protocol.default_page_size & info [ "limit" ] ~docv:"COUNT")
;;

let format_term =
  Arg.(value & opt (enum [ "json", `Json ]) `Json & info [ "format" ] ~docv:"FORMAT")
;;

let input_term =
  Arg.(value & opt (enum [ "ndjson", `Ndjson ]) `Ndjson & info [ "input" ] ~docv:"FORMAT")
;;

let source_graph_name_term =
  Arg.(value & opt (some string) None & info [ "source-graph-name" ] ~docv:"NAME")
;;

let inbox_entry_term =
  Arg.(value & opt (some string) None & info [ "inbox-entry" ] ~docv:"ENTRY")
;;

let require_option name = function
  | Some value -> Ok value
  | None -> Error (name ^ " is required for this command")
;;

let dispatch
      path
      support
      snapshot_token
      graph_name
      import_inbox_entry
      uuid
      request_path
      limit
      _format
      input
      source_graph_name
      inbox_entry
  =
  let with_target action =
    build_config support snapshot_token graph_name import_inbox_entry
    |> with_config action
  in
  match path with
  | [ "graph"; "info" ] ->
    with_target (fun config ->
      run_request
        config
        Protocol.{ api_version; request_id = random_uuid (); command = Read Graph_info })
  | [ "block"; "get" ] ->
    (match require_option "--uuid" uuid with
     | Error message -> report_error Local_error message
     | Ok uuid ->
       with_target (fun config ->
         match Logseq_db_worker.Graph_types.Uuid.of_string uuid with
         | Error message -> report_error Local_error message
         | Ok block ->
           run_request
             config
             Protocol.
               { api_version
               ; request_id = random_uuid ()
               ; command = Read (Get_block { block })
               }))
  | [ "block"; "children" ] ->
    (match require_option "--uuid" uuid with
     | Error message -> report_error Local_error message
     | Ok uuid ->
       with_target (fun config ->
         match Logseq_db_worker.Graph_types.Uuid.of_string uuid with
         | Error message -> report_error Local_error message
         | Ok parent ->
           run_request
             config
             Protocol.
               { api_version
               ; request_id = random_uuid ()
               ; command = Read (Get_children { parent; limit; cursor = None })
               }))
  | ([ "block"; "save" ] | [ "request" ]) as command_path ->
    (match require_option "--request" request_path with
     | Error message -> report_error Local_error message
     | Ok path ->
       with_target (fun config ->
         match request_from_file path with
         | Error message -> report_error Local_error message
         | Ok request ->
           let validation =
             if command_path = [ "block"; "save" ]
             then save_block_request request
             else Ok ()
           in
           (match validation with
            | Error message -> report_error Local_error message
            | Ok () -> run_request config request)))
  | [ "session" ] ->
    with_target (fun config ->
      match input with
      | `Ndjson -> run_ndjson_channels config)
  | [ "snapshot"; "create" ] ->
    (match require_option "--source-graph-name" source_graph_name with
     | Error message -> report_error Local_error message
     | Ok source_graph_name ->
       (match ensure_directory support, Sys.getenv_opt "HOME" with
        | Error message, _ -> report_error Local_error message
        | _, None ->
          report_error Local_error "HOME is required to resolve the source graph"
        | Ok support, Some home_directory ->
          (match
             Graph_locator.resolve
               (Desktop { home_directory })
               ~graph_name:source_graph_name
           with
           | Error error -> report_error Execute_error (graph_locator_error error)
           | Ok source ->
             (match
                create_snapshot
                  ~application_support_directory:support
                  ~source_graph_dir:source.graph_dir
              with
              | Error message -> report_error Execute_error message
              | Ok token ->
                print_endline
                  (Yojson.Safe.to_string
                     (`Assoc
                         [ "apiVersion", `Int Protocol.api_version
                         ; ( "snapshotToken"
                           , `String (Logseq_db_worker.Graph_types.Uuid.to_string token) )
                         ]));
                Cli_output.exit_code Success))))
  | [ "snapshot"; "import" ] ->
    (match require_option "--inbox-entry" inbox_entry with
     | Error message -> report_error Local_error message
     | Ok inbox_entry ->
       (match ensure_directory support with
        | Error message -> report_error Local_error message
        | Ok support ->
          (match import_snapshot ~application_support_directory:support ~inbox_entry with
           | Error message -> report_error Execute_error message
           | Ok token ->
             print_endline
               (Yojson.Safe.to_string
                  (`Assoc
                      [ "apiVersion", `Int Protocol.api_version
                      ; ( "snapshotToken"
                        , `String (Logseq_db_worker.Graph_types.Uuid.to_string token) )
                      ]));
             Cli_output.exit_code Success)))
  | [] -> report_error Local_error "a command is required"
  | _ -> report_error Local_error "unknown command"
;;

let command =
  let exits =
    [ Cmd.Exit.info 0 ~doc:"The command or NDJSON session completed."
    ; Cmd.Exit.info 2 ~doc:"CLI syntax or local request decoding failed."
    ; Cmd.Exit.info 3 ~doc:"A dispatched operation returned an execute failure."
    ; Cmd.Exit.info 4 ~doc:"The graph returned an open failure."
    ; Cmd.Exit.info 5 ~doc:"A fatal persistence or lifecycle failure occurred."
    ]
  in
  Cmd.v
    (Cmd.info
       "logseq-db-worker"
       ~version:"0.1.0"
       ~exits
       ~doc:"Read and mutate a local Logseq DB graph through one shared Engine.")
    Term.(
      const dispatch
      $ command_path_term
      $ support_term
      $ snapshot_token_term
      $ graph_name_term
      $ inbox_target_term
      $ optional_uuid_term
      $ optional_request_path_term
      $ limit_term
      $ format_term
      $ input_term
      $ source_graph_name_term
      $ inbox_entry_term)
;;

module For_testing = struct
  let execute_once = execute_once_with
end

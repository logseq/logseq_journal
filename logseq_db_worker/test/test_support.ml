type case =
  { name : string
  ; run : unit -> unit
  }

let case name run = { name; run }
let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let read_json path = Yojson.Safe.from_file path

let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory "dune-project")
  then directory
  else (
    let parent = Filename.dirname directory in
    if String.equal parent directory
    then fail "unable to locate repository root"
    else repository_root parent)
;;

let root = repository_root (Sys.getcwd ())

let fixture relative =
  Filename.concat root (Filename.concat "logseq_db_worker/test/fixtures" relative)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let overlay_dependencies () =
  let limits =
    Logseq_overlay_db.Types.
      { response_budget_bytes = Logseq_db_worker.Protocol.maximum_response_bytes
      ; outbox_max_records = 4_096
      ; outbox_max_bytes = 8 * 1024 * 1024
      ; change_max_items = Logseq_db_worker.Protocol.maximum_changed_uuids
      ; change_max_bytes = Logseq_db_worker.Protocol.maximum_push_bytes
      ; dispatcher_capacity = 256
      ; wire_batch_max_bytes = Logseq_db_worker.Protocol.maximum_response_bytes
      }
  in
  Logseq_overlay_db.Database.dependencies
    ~epoch_ms:(fun () -> 1_700_000_000_000L)
    ~monotonic_ns:(fun () -> 1L)
    ~limits
  |> Result.get_ok
;;

type managed_fixture =
  { config : Logseq_db_worker.Config.t
  ; overlay : Logseq_overlay_db.Database.dependencies
  }

let with_managed f =
  let support = Filename.temp_file "logseq-worker-test-" "" in
  Sys.remove support;
  Unix.mkdir support 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree support)
    (fun () ->
       let config =
         Logseq_db_worker.Config.create
           ~application_support_directory:support
           ~target:(Managed_sync { base_url = "https://api.logseq.io" })
           ~compatibility_profile:Logseq_65_33_or_newer
           ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
           ~default_page_size:Logseq_db_worker.Protocol.default_page_size
         |> Result.get_ok
       in
       f { config; overlay = overlay_dependencies () })
;;

let run suite cases =
  let failures =
    List.filter_map
      (fun case ->
         try
           case.run ();
           None
         with
         | exn -> Some (Printf.sprintf "%s: %s" case.name (Printexc.to_string exn)))
      cases
  in
  match failures with
  | [] -> ()
  | _ -> fail "%s failures:\n%s" suite (String.concat "\n" failures)
;;

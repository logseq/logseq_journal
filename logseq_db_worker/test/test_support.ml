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
let fixture relative = Filename.concat root (Filename.concat "logseq_db_worker/test/fixtures" relative)

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

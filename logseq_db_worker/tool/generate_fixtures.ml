module Generator = Logseq_db_worker_fixture_generator.Fixture_generator

let usage =
  "usage: generate_fixtures \
   (encrypted-offline-warm-start|runtime-flow|runtime-flow-pagination|runtime-flow-failure) \
   --support-root ROOT"
;;

let parse arguments =
  match arguments with
  | [ mode; "--support-root"; support_root ] ->
    (match mode with
     | "encrypted-offline-warm-start" -> Ok (`Encrypted_warm_start, support_root)
     | "runtime-flow" -> Ok (`Snapshot Generator.Runtime_flow, support_root)
     | "runtime-flow-pagination" ->
       Ok (`Snapshot Generator.Runtime_flow_with_pagination, support_root)
     | "runtime-flow-failure" ->
       Ok (`Snapshot Generator.Runtime_flow_with_persistence_failure, support_root)
     | _ -> Error usage)
  | _ -> Error usage
;;

let () =
  match Array.to_list Sys.argv |> List.tl |> parse with
  | Error message ->
    prerr_endline message;
    exit 2
  | Ok (`Encrypted_warm_start, support_root) ->
    (match Generator.create_encrypted_warm_start ~support_root with
     | Error message ->
       prerr_endline message;
       exit 1
     | Ok generated ->
       Generator.managed_to_yojson generated |> Yojson.Safe.to_string |> print_endline)
  | Ok (`Snapshot mode, support_root) ->
    (match Generator.create ~support_root ~mode with
     | Error message ->
       prerr_endline message;
       exit 1
     | Ok generated ->
       Generator.to_yojson generated |> Yojson.Safe.to_string |> print_endline)
;;

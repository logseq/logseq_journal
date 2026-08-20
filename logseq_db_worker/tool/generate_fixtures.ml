module Generator = Logseq_db_worker_fixture_generator.Fixture_generator

let usage =
  "usage: generate_fixtures (runtime-flow|runtime-flow-pagination|runtime-flow-failure) \
   --support-root ROOT"
;;

let parse arguments =
  match arguments with
  | [ mode; "--support-root"; support_root ] ->
    let mode =
      match mode with
      | "runtime-flow" -> Ok Generator.Runtime_flow
      | "runtime-flow-pagination" -> Ok Runtime_flow_with_pagination
      | "runtime-flow-failure" -> Ok Runtime_flow_with_persistence_failure
      | _ -> Error usage
    in
    Result.map (fun mode -> mode, support_root) mode
  | _ -> Error usage
;;

let () =
  match Array.to_list Sys.argv |> List.tl |> parse with
  | Error message ->
    prerr_endline message;
    exit 2
  | Ok (mode, support_root) ->
    (match Generator.create ~support_root ~mode with
     | Error message ->
       prerr_endline message;
       exit 1
     | Ok generated ->
       Generator.to_yojson generated |> Yojson.Safe.to_string |> print_endline)
;;

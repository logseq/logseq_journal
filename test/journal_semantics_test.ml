module Ui = Journal_view

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected fixture rejection: %s" error
;;

let block_id = "20000000-0000-4000-a000-000000000001"
let page_id = "20000000-0000-4000-b000-000000000001"
let mutation_id = "20000000-0000-4000-9000-000000000001"

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_786_237_500_000L
    ~local_day:20260809
    ~local_minute_of_day:545
  |> require_ok
;;

let block
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Done)
      ?(child_count = 3)
      ()
  =
  Journal_model.create
    ~id:block_id
    ~page_id
    ~journal_day:20260809
    ~parent_id:None
    ~sibling_order:"000000000001"
    ~source
    ~task_state
    ~child_count
    ~creation_time
    ~revision:"block-4"
    ~last_mutation_id:mutation_id
  |> require_ok
;;

module V = Ui.View

let test_timeline_media_targets () =
  let targets = ref [] in
  ignore
    (Journal_row.view
       ~show_timestamp:false
       ~render_media:(fun ~root child ->
         targets := root :: !targets;
         child)
       { Journal_graph_projection.block = block ()
       ; child_summaries = [ { block_id = "visible-child"; source = "Summary" } ]
       }
     : V.t);
  require
    (List.sort String.compare !targets
     = List.sort String.compare [ block_id; "visible-child" ])
    "media discovery must target each displayed source, including summaries"
;;

let tests = [ "timeline media targets", test_timeline_media_targets ]

let () =
  let failed =
    List.filter_map
      (fun (name, run) ->
         Printf.printf "running %s\n%!" name;
         try
           run ();
           None
         with
         | error ->
           Printf.eprintf "%s: %s\n%!" name (Printexc.to_string error);
           Some name)
      tests
  in
  if failed <> [] then fail "Failed: %s" (String.concat ", " failed)
;;

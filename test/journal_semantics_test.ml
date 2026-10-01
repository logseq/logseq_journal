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

let test_native_lui_events () =
  let received = ref [] in
  let loading = ref 0 in
  Journal_bridge.register
    { init = (fun _ _ _ -> "")
    ; dispatch =
        (fun event ->
          received := event :: !received;
          "")
    ; extension_event = (fun _ _ _ -> "")
    ; pump = (fun () -> "")
    ; platform_event = (fun _ -> ())
    ; platform_response = (fun _ -> ())
    ; platform_failure = (fun _ -> ())
    ; dispose = (fun () -> "")
    ; root_node = (fun () -> 0)
    ; loading_signal = (fun () -> !loading)
    };
  loading := 1;
  require (Journal_bridge.loading_signal () = 1) "native loading signal was not forwarded";
  ignore (Journal_bridge.scroll_completed 7 42 "unavailable");
  ignore (Journal_bridge.visible_range 8 0 14);
  ignore (Journal_bridge.picked 9 {|{"token":11,"files":[{"name":"日记.md"}]}|});
  require
    (List.rev !received
     = [ Lui_protocol.ScrollCompleted (7, 42, "unavailable")
       ; Lui_protocol.VisibleRange (8, 0, 14)
       ; Lui_protocol.Picked (9, {|{"token":11,"files":[{"name":"日记.md"}]}|})
       ])
    "native LUI events must preserve their node IDs and payloads"
;;

let tests =
  [ "timeline media targets", test_timeline_media_targets
  ; "native LUI events", test_native_lui_events
  ]
;;

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

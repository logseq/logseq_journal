module Timeline = Journal_timeline_state
module Ui = Journal_view
module V = Ui.View

module Store = struct
  type listener =
    { epoch : int
    ; mutable active : bool
    ; callback : unit -> unit
    ; mutable pending : bool
    }

  type shape =
    | Block of string * int
    | Other of Timeline.slot * string option * bool

  type t =
    { rows : (string, Journal_graph_projection.timeline_entry) Hashtbl.t
    ; listeners : (string, (int, listener) Hashtbl.t) Hashtbl.t
    ; scroll_listeners : (int, listener) Hashtbl.t
    ; mutable scroll_target : (int64 * int * string) option
    ; observe : string -> unit
    ; mutable last : Timeline.t option
    ; mutable shape : (int * shape list) option
    ; mutable revision : int
    ; mutable epoch : int
    ; mutable active : bool
    ; mutable serial : int
    }

  let create ?(observe = fun _ -> ()) () =
    { rows = Hashtbl.create 64
    ; listeners = Hashtbl.create 64
    ; scroll_listeners = Hashtbl.create 2
    ; scroll_target = None
    ; observe
    ; last = None
    ; shape = None
    ; revision = 0
    ; epoch = 0
    ; active = true
    ; serial = 0
    }
  ;;

  let find t block_id = Hashtbl.find_opt t.rows block_id

  let scroll_target t = t.scroll_target

  let subscribe_scroll t callback =
    t.serial <- t.serial + 1;
    let id = t.serial in
    let listener = { epoch = t.epoch; active = true; callback; pending=false } in
    Hashtbl.add t.scroll_listeners id listener;
    fun () ->
      listener.active <- false;
      Hashtbl.remove t.scroll_listeners id
  ;;

  let publish_scroll t target =
    if t.scroll_target <> target then (
      t.scroll_target <- target;
      let listeners = Hashtbl.fold (fun _ value rest -> value :: rest) t.scroll_listeners [] in
      List.iter (fun (listener:listener) ->
        if listener.active && listener.epoch = t.epoch then
          if t.active then listener.callback () else listener.pending<-true) listeners)
  ;;

  let subscribe t block_id callback =
    let bucket =
      match Hashtbl.find_opt t.listeners block_id with
      | Some bucket -> bucket
      | None ->
        let bucket = Hashtbl.create 2 in
        Hashtbl.add t.listeners block_id bucket;
        bucket
    in
    t.serial <- t.serial + 1;
    let id = t.serial in
    let listener = { epoch = t.epoch; active = true; callback; pending=false } in
    Hashtbl.add bucket id listener;
    fun () ->
      if listener.active
      then (
        listener.active <- false;
        Hashtbl.remove bucket id;
        if Hashtbl.length bucket = 0 then Hashtbl.remove t.listeners block_id)
  ;;

  let notify t block_id =
    Option.iter
      (fun bucket ->
         let listeners = Hashtbl.fold (fun _ value rest -> value :: rest) bucket [] in
         List.iter
           (fun (listener:listener) ->
              if listener.active && listener.epoch = t.epoch
              then (
                if t.active then (t.observe "timeline-item-notify";listener.callback ())
                else listener.pending<-true))
           listeners)
      (Hashtbl.find_opt t.listeners block_id)
  ;;

  let set_active t active =
    if t.active<>active then (
      t.active<-active;
      if active then (
        let rows=Hashtbl.fold(fun _ bucket rest->
          Hashtbl.fold(fun _ listener rest->listener::rest) bucket rest) t.listeners [] in
        let pending=Hashtbl.fold(fun _ listener rest->listener::rest) t.scroll_listeners rows in
        List.iter(fun (listener:listener)->
          if listener.pending && listener.active && listener.epoch=t.epoch && t.active then (
            listener.pending<-false;listener.callback ())) pending))
  ;;

  (* Only a changed timeline presentation reaches this traversal. Media,
     navigation, draft and visible-demand writes do not scan retained rows. *)
  let synchronize t state =
    publish_scroll t (Timeline.scroll_target state);
    let same =
      Option.fold
        ~none:false
        ~some:(fun old -> Timeline.equal_presentation old state)
        t.last
    in
    t.last <- Some state;
    if not same
    then (
      let seen = Hashtbl.create (Timeline.retained_slot_count state) in
      let changes = ref [] in
      let shape =
        Timeline.fold_slots
          (fun reversed slot ->
             let shape =
               match slot with
               | Timeline.Top_level entry ->
                 let block_id = Journal_model.id entry.block in
                 Hashtbl.replace seen block_id ();
                 t.observe "timeline-item-compare";
                 if find t block_id <> Some entry
                 then (
                   Hashtbl.replace t.rows block_id entry;
                   changes := block_id :: !changes);
                 Block (block_id, Journal_model.journal_day entry.block)
               | Day_continuation { day; _ } ->
                 Other
                   ( slot
                   , Timeline.day_error state ~day
                   , Option.is_some (Timeline.pending_request state) )
               | Day_heading _ | Feed_continuation _ -> Other (slot, None, false)
             in
             shape :: reversed)
          []
          state
        |> List.rev
      in
      let removed =
        Hashtbl.fold
          (fun block_id _ rest ->
             if Hashtbl.mem seen block_id then rest else block_id :: rest)
          t.rows
          []
      in
      List.iter (Hashtbl.remove t.rows) removed;
      let shape = Some (Timeline.today state, shape) in
      if t.shape <> shape
      then (
        t.shape <- shape;
        t.revision <- t.revision + 1;
        t.observe "timeline-structure-change");
      List.iter (notify t) (List.rev_append !changes removed));
    t.revision
  ;;

  let reset t =
    publish_scroll t None;
    t.epoch <- t.epoch + 1;
    t.last <- None;
    t.shape <- None;
    Hashtbl.clear t.rows
  ;;
end

let loading_view () = V.loading ~centered:true ~message:"Loading journal" ()

let view
      ?status_name
      ?creator_name
      ?current_day
      ?store
      ?on_sync
      ?(on_region = fun _ -> ())
      ~render_source
      ?render_title
      ~render_media
      ~state
      ~day_presentation
      ~on_visible_range
      ~on_scroll_completed
      ~on_retry_day:_
      ~on_open_block
      ~delete_enabled
      ~actions_enabled
      ~on_status
      ~on_delete
      ~on_copy
      ()
  =
  let slots = Timeline.fold_slots (fun acc slot -> slot :: acc) [] state |> List.rev in
  let today = Timeline.today state in
  let current_day = Option.value current_day ~default:today in
  let metadata index slot : Journal_native_collection.row =
    let section, header, block_id =
      match slot with
      | Timeline.Day_heading page -> string_of_int page.day, true, None
      | Top_level entry ->
        ( string_of_int (Journal_model.journal_day entry.block)
        , false
        , Some (Journal_model.id entry.block) )
      | Day_continuation { day; _ } -> string_of_int day, false, None
      | Feed_continuation _ -> "older-days", false, None
    in
    { id = Timeline.slot_key slot; section; header; slot_index = Some index; block_id }
  in
  let heading day fallback =
    let title =
      match day_presentation day with
      | Some value -> value.Journal_calendar.date_text
      | None -> fallback
    in
    Journal_header.date_header
      ?relative_label:(Journal_calendar.relative_day_label ~today:current_day day)
      ~title ()
    |> V.with_test_id (Ui.Test_id.string ("journal-day-heading:" ^ string_of_int day))
  in
  let render slot =
    let child =
      match slot with
      | Timeline.Day_heading page -> heading page.day page.title
      | Top_level entry ->
        let render entry =
          on_region "timeline-item-build";
          Journal_row.view
            ?status_name
            ?creator_name
            ~render_source
            ?render_title
            ~render_media entry
        in
        (match store with
         | None -> render entry
         | Some store ->
           V.of_lui (fun context parent ->
             let block_id = Journal_model.id entry.block in
             let current =
               Signal.state context.Lui_ui.ui_scheduler (Store.find store block_id)
             in
             let unsubscribe =
               Store.subscribe store block_id (fun () ->
                 Signal.set current (Store.find store block_id))
             in
             Signal.on_dispose context.ui_scope (fun () ->
               unsubscribe ();
               Signal.dispose_signal (Signal.value current));
             Lui_elements.dyn
               ~equal:( = )
               (function
                 | None -> Journal_view.mount (V.column [])
                 | Some entry -> Journal_view.mount (render entry))
               (Signal.value current)
               context
               parent))
      | Day_continuation { day; _ } ->
        (match Timeline.day_error state ~day with
         | None -> V.loading ~message:"Loading more journal entries" ()
         | Some message ->
           V.text message)
      | Feed_continuation _ -> V.loading ~message:"Loading older journal days" ()
    in
    V.column ~key:(Ui.Key.string (Timeline.slot_key slot)) [ child ]
  in
  let synthetic_heading day =
    let section = string_of_int day in
    ( { Journal_native_collection.id = "day:" ^ section
      ; section
      ; header = true
      ; slot_index = None
      ; block_id = None
      }
    , V.column ~key:(Ui.Key.string ("day:" ^ section)) [ heading day "Date unavailable" ]
    )
  in
  let rec present previous_section = function
    | [] -> []
    | (index, slot) :: rest ->
      let row = metadata index slot in
      let date =
        match slot with
        | Timeline.Top_level entry -> Some (Journal_model.journal_day entry.block)
        | Day_continuation { day; _ } -> Some day
        | Day_heading _ | Feed_continuation _ -> None
      in
      let header =
        match date with
        | Some day when previous_section <> Some row.section -> [ synthetic_heading day ]
        | _ -> []
      in
      header
      @ ((row, render slot) :: present (Some row.section) rest)
  in
  let presented = present None (List.mapi (fun index slot -> index, slot) slots) in
  let presented =
    if
      not
        (List.exists
           (fun (row, _) -> row.Journal_native_collection.section = string_of_int today)
           presented)
    then synthetic_heading today :: presented
    else presented
  in
  let rows, children = List.split presented in
  let scroll_target target =
    Option.bind target (fun (token, day, row) ->
      let section = string_of_int day in
      if String.equal row ("day:" ^ section) then
        (* Empty Today can be synthesized before future slots. Resolve the
           top intent from the actual presentation, preserving Capture rows. *)
        (match rows with
         | [] -> None
         | (first : Journal_native_collection.row) :: _ ->
           Some (token, first.section, "day:" ^ first.section))
      else Some (token, section, row))
  in
  let collection ?scroll_target_signal target =
    Journal_native_collection.view
    ~key:(Ui.Key.string "journal-timeline-list")
    ~test_id:(Ui.Test_id.string "journal-timeline")
    ~rows
    ~scroll_target:target
    ?scroll_target_signal
    ?on_sync
    ~on_scroll_completed
    ~actions_enabled:(delete_enabled && actions_enabled)
    ~on_visible_range
    ~on_open:on_open_block
    ~on_status
    ~on_delete
    ~on_copy
    ~children
    ()
  in
  (match store with
   | None -> collection (scroll_target (Timeline.scroll_target state))
   | Some store -> V.of_lui (fun context parent ->
       let command = Signal.state context.Lui_ui.ui_scheduler
         (scroll_target (Store.scroll_target store)) in
       let unsubscribe = Store.subscribe_scroll store (fun () ->
         Signal.set command (scroll_target (Store.scroll_target store))) in
       Signal.on_dispose context.ui_scope (fun () ->
         unsubscribe ();
         Signal.dispose_signal (Signal.value command));
       Ui.mount (collection ~scroll_target_signal:(Signal.value command) None) context parent))
  |> fun content -> V.of_lui
    (Journal_lui_native.mount ~key:"journal-timeline-mode"
       ~payload:{|{"mode":"timeline-interaction"}|}
       ~children:[ Ui.mount content ] Journal_lui_native.chrome_identifier)
  |> V.Body.Vertical.fill
  |> fun content -> V.Body.Vertical.create [ content ]
;;

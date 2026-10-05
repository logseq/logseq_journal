module Timeline = Journal_timeline_state
module Ui = Journal_view
module V = Ui.View

let for_block handler block_id =
  Ui.Event.Handler.create ~name:("journal-block:" ^ block_id) (fun _ ->
    Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text block_id))
;;

let same_creation_minute left right =
  let left = Journal_model.creation_time left in
  let right = Journal_model.creation_time right in
  Journal_time.local_day left = Journal_time.local_day right
  && Journal_time.local_minute_of_day left = Journal_time.local_minute_of_day right
;;

let should_show_timestamp ~today ~previous_slot = function
  | Timeline.Top_level entry when Journal_model.journal_day entry.block = today ->
    (match previous_slot with
     | Some (Timeline.Top_level previous) ->
       not (same_creation_minute previous.block entry.block)
     | Some _ | None -> true)
  | Top_level _ | Day_heading _ | Day_continuation _ | Feed_continuation _ -> false
;;

module Store = struct
  type row =
    { entry : Journal_graph_projection.timeline_entry
    ; show_timestamp : bool
    }

  type listener =
    { epoch : int
    ; mutable active : bool
    ; callback : unit -> unit
    }

  type shape =
    | Block of string * int
    | Other of Timeline.slot * string option * bool

  type t =
    { rows : (string, row) Hashtbl.t
    ; listeners : (string, (int, listener) Hashtbl.t) Hashtbl.t
    ; observe : string -> unit
    ; mutable last : Timeline.t option
    ; mutable shape : (int * (int64 * int * string) option * shape list) option
    ; mutable revision : int
    ; mutable epoch : int
    ; mutable serial : int
    }

  let create ?(observe = fun _ -> ()) () =
    { rows = Hashtbl.create 64
    ; listeners = Hashtbl.create 64
    ; observe
    ; last = None
    ; shape = None
    ; revision = 0
    ; epoch = 0
    ; serial = 0
    }
  ;;

  let find t block_id = Hashtbl.find_opt t.rows block_id

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
    let listener = { epoch = t.epoch; active = true; callback } in
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
           (fun listener ->
              if listener.active && listener.epoch = t.epoch
              then (
                t.observe "timeline-item-notify";
                listener.callback ()))
           listeners)
      (Hashtbl.find_opt t.listeners block_id)
  ;;

  (* Only a changed timeline presentation reaches this traversal. Media,
     navigation, draft and visible-demand writes do not scan retained rows. *)
  let synchronize t state =
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
      let previous = ref None in
      let shape =
        Timeline.fold_slots
          (fun reversed slot ->
             let shape =
               match slot with
               | Timeline.Top_level entry ->
                 let block_id = Journal_model.id entry.block in
                 let row =
                   { entry
                   ; show_timestamp =
                       should_show_timestamp
                         ~today:(Timeline.today state)
                         ~previous_slot:!previous
                         slot
                   }
                 in
                 Hashtbl.replace seen block_id ();
                 t.observe "timeline-item-compare";
                 if find t block_id <> Some row
                 then (
                   Hashtbl.replace t.rows block_id row;
                   changes := block_id :: !changes);
                 Block (block_id, Journal_model.journal_day entry.block)
               | Day_continuation { day; _ } ->
                 Other
                   ( slot
                   , Timeline.day_error state ~day
                   , Option.is_some (Timeline.pending_request state) )
               | Day_heading _ | Feed_continuation _ -> Other (slot, None, false)
             in
             previous := Some slot;
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
      let shape = Some (Timeline.today state, Timeline.scroll_target state, shape) in
      if t.shape <> shape
      then (
        t.shape <- shape;
        t.revision <- t.revision + 1;
        t.observe "timeline-structure-change");
      List.iter (notify t) (List.rev_append !changes removed));
    t.revision
  ;;

  let reset t =
    t.epoch <- t.epoch + 1;
    t.last <- None;
    t.shape <- None;
    Hashtbl.clear t.rows
  ;;
end

let loading_view () = V.loading ~centered:true ~message:"Loading journal" ()

let view
      ?store
      ?(on_region = fun _ -> ())
      ~render_source
      ~render_media
      ~state
      ~day_presentation
      ~on_visible_range
      ~on_scroll_completed
      ~on_retry_day
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
    Journal_header.date_header ~title
    |> V.with_test_id (Ui.Test_id.string ("journal-day-heading:" ^ string_of_int day))
  in
  let render previous_slot slot =
    let child =
      match slot with
      | Timeline.Day_heading page -> heading page.day page.title
      | Top_level entry ->
        let render entry show_timestamp =
          on_region "timeline-item-build";
          Journal_row.view ~render_source ~render_media ~show_timestamp entry
        in
        (match store with
         | None -> render entry (should_show_timestamp ~today ~previous_slot slot)
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
                 | Some (row : Store.row) ->
                   Journal_view.mount (render row.entry row.show_timestamp))
               (Signal.value current)
               context
               parent))
      | Day_continuation { day; _ } ->
        (match Timeline.day_error state ~day with
         | None -> V.loading ~message:"Loading more journal entries" ()
         | Some message ->
           V.column
             [ V.text message
             ; V.button
                 ~enabled:(Option.is_none (Timeline.pending_request state))
                 ~on_press:(for_block on_retry_day (string_of_int day))
                 ~child:(V.text "Retry")
                 ()
               |> V.with_test_id
                    (Ui.Test_id.string ("journal-day-retry:" ^ string_of_int day))
             ])
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
  let rec present previous_section previous_slot = function
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
      @ ((row, render previous_slot slot) :: present (Some row.section) (Some slot) rest)
  in
  let presented = present None None (List.mapi (fun index slot -> index, slot) slots) in
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
  Journal_native_collection.view
    ~key:(Ui.Key.string "journal-timeline-list")
    ~test_id:(Ui.Test_id.string "journal-timeline")
    ~rows
    ~scroll_target:
      (Option.map
         (fun (token, day, row) -> token, string_of_int day, row)
         (Timeline.scroll_target state))
    ~on_scroll_completed
    ~actions_enabled:(delete_enabled && actions_enabled)
    ~on_visible_range
    ~on_open:on_open_block
    ~on_status
    ~on_delete
    ~on_copy
    ~children
  |> V.Body.Vertical.fill
  |> fun content -> V.Body.Vertical.create [ content ]
;;

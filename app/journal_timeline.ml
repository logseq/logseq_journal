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

let loading_view () =
  V.column [ V.progress ~style:Circular (); V.text "Loading journal" ]
  |> V.frame ~max_width:Fill ~max_height:Fill
;;

let view
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
        Journal_row.view
          ~render_media
          ~show_timestamp:(should_show_timestamp ~today ~previous_slot slot)
          entry
      | Day_continuation { day; _ } ->
        (match Timeline.day_error state ~day with
         | None ->
           V.row [ V.progress ~style:Circular (); V.text "Loading more journal entries" ]
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
      | Feed_continuation _ ->
        V.row [ V.progress ~style:Circular (); V.text "Loading older journal days" ]
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
      Timeline.first_retained_index state = 0
      && not
           (List.exists
              (fun (row, _) ->
                 row.Journal_native_collection.section = string_of_int today)
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
    ~children
  |> V.Body.Vertical.fill
  |> fun content -> V.Body.Vertical.create [ content ]
;;

module Ui = Journal_view
module V = Ui.View

type row =
  { id : string
  ; section : string
  ; header : bool
  ; slot_index : int option
  ; block_id : string option
  }

let action handler id =
  Ui.Event.Handler.create (fun _ ->
    Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text id))
;;

let view
      ~key
      ~test_id
      ~rows
      ~scroll_target
      ~on_scroll_completed
      ~actions_enabled
      ~on_visible_range
      ~on_open
      ~on_status
      ~on_delete
      ~children
  =
  let indexed =
    List.map (fun (row, child) -> row.slot_index, row, child) (List.combine rows children)
  in
  let rec groups = function
    | [] -> []
    | ((_, first, _) as head) :: rest ->
      let rec take acc = function
        | ((_, row, _) as item) :: rest when row.section = first.section ->
          take (item :: acc) rest
        | rest -> List.rev acc, rest
      in
      let group, rest = take [ head ] rest in
      (first.section, group) :: groups rest
  in
  let indices = ref [] in
  let render_row (index, row, child) =
    indices := index :: !indices;
    let row_key = Ui.Key.string row.id in
    match row.block_id with
    | None -> V.Native_list.row ~key:row_key ~separator:Hidden child
    | Some id ->
      let status = action on_status id
      and delete = action on_delete id in
      let swipe_actions =
        V.Swipe_actions.create
          ~allows_full_swipe:false
          ~actions:
            [ V.Swipe_actions.action
                ~key:(Ui.Key.string ("status:" ^ id))
                ~enabled:actions_enabled
                ~side:Start
                ~title:"Status"
                ~symbol:"checkmark.circle"
                ~background:Journal_visual_tokens.status_action_background
                ~on_press:status
                ()
            ; V.Swipe_actions.action
                ~key:(Ui.Key.string ("delete:" ^ id))
                ~enabled:actions_enabled
                ~side:End
                ~title:"Delete"
                ~symbol:"trash"
                ~role:Destructive
                ~background:Journal_visual_tokens.delete_action_background
                ~on_press:delete
                ()
            ]
          ()
      in
      let context_menu =
        V.Context_menu.create
          ~actions:
            [ V.Context_menu.action
                ~key:(Ui.Key.string "status")
                ~enabled:actions_enabled
                ~title:"Change status"
                ~symbol:"checkmark.circle"
                ~on_press:status
                ()
            ; V.Context_menu.action
                ~key:(Ui.Key.string "delete")
                ~enabled:actions_enabled
                ~title:"Delete block and descendants"
                ~symbol:"trash"
                ~role:Destructive
                ~on_press:delete
                ()
            ]
          ()
      in
      V.Native_list.row
        ~key:row_key
        ~separator:Hidden
        ~swipe_actions
        ~context_menu
        (V.Navigation_link.create
           ~key:(Ui.Key.string ("open:" ^ id))
           ~activation_id:id
           ~enabled:actions_enabled
           ~on_activate:(action on_open id)
           ~label:child
           ())
  in
  let sections =
    List.map
      (fun (section, group) ->
         let header = List.find_opt (fun (_, row, _) -> row.header) group in
         let content = List.filter (fun (_, row, _) -> not row.header) group in
         let content =
           match content, header with
           | [], Some (index, row, _) ->
             [ ( index
               , { row with header = false; id = "empty:" ^ row.id }
               , V.text "No journal entries" )
             ]
           | _ -> content
         in
         V.Native_list.section
           ~key:(Ui.Key.string section)
           ?header:(Option.map (fun (_, _, child) -> child) header)
           ~separator:Hidden
           (List.map render_row content))
      (groups indexed)
  in
  let indices = Array.of_list (List.rev !indices) in
  let on_visible_range =
    Ui.Event.Handler.create (function
      | Ui.Event.Payload.Visible_range { first_index; last_exclusive }
        when first_index >= 0L
             && last_exclusive > first_index
             && last_exclusive <= Int64.of_int (Array.length indices) ->
        let first = Int64.to_int first_index in
        let length = Int64.to_int last_exclusive - first in
        let visible =
          Array.sub indices first length |> Array.to_list |> List.filter_map Fun.id
        in
        (match visible with
         | [] -> ()
         | first :: rest ->
           let last = List.fold_left (fun _ index -> index) first rest in
           Ui.Event.Handler.Private.invoke
             on_visible_range
             (Ui.Event.Payload.Visible_range
                { first_index = Int64.of_int first
                ; last_exclusive = Int64.of_int (last + 1)
                }))
      | _ -> ())
  in
  let scroll_request =
    Option.map
      (fun (token, section, row) ->
         V.Native_list.scroll_request
           ~token
           ~target:
             (V.Native_list.target
                ~section:(Ui.Key.string section)
                ~row_path:[ Ui.Key.string row ])
           ~anchor:Top
           ~animated:false
           ())
      scroll_target
  in
  V.Native_list.vertical
    ~key
    ~style:Plain
    ?scroll_request
    ~on_scroll_completed
    ~on_visible_range
    sections
  |> V.Viewport.Vertical.with_test_id test_id
  |> V.Viewport.Vertical.overlay
       ~key:(Ui.Key.string "journal-empty-presentation")
       ~overlay:
         (if rows = []
          then
            V.content_unavailable
              ~label:
                (V.label
                   ~title:(V.text "No journal entries yet")
                   ~icon:(V.symbol ~name:"book" ())
                   ())
              ()
          else V.empty ())
;;

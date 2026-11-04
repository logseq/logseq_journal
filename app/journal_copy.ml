module Pure = struct
  module Graph = Logseq_db_types.Graph_types
  module Worker = Journal_worker_coordination.Worker_api
  module Protocol = Worker.Protocol
  module Keys = Set.Make (String)

  type frame =
    { parent : Graph.Uuid.t
    ; depth : int
    ; cursor : Protocol.v2_child_member Worker.continuation option
    ; revision : string option
    ; cursors : Protocol.v2_child_member Worker.continuation Rrbvec.t
    ; gathered : Protocol.v2_child_member Rrbvec.t
    ; gathered_bytes : int
    ; remaining : int option
    }

  type phase =
    | Before
    | Root
    | Page_root
    | Children
    | After

  type job =
    { root : Graph.block_uuid
    ; page : Graph.page_uuid option
    ; version : (Graph.Uuid.t * string * string) option
    ; phase : phase
    ; frames : frame list
    ; visited : Keys.t
    ; fragments : string Rrbvec.t
    ; bytes : int
    }

  type t =
    { next_ticket : int64
    ; awaiting : int64 option
    ; job : job option
    }

  type result =
    | Info_result of Worker.graph_info
    | Block_result of Protocol.v2_block_lookup
    | Page_result of Protocol.v2_page_lookup
    | Children_result of Worker.children

  type event =
    | Start of Graph.block_uuid
    | Completed of int64 * result
    | Read_failed of int64 * string
    | Cancel

  type output_action =
    | Read : int64 * 'a Worker.query * ('a -> result) -> output_action
    | Copied of string
    | Failed of string

  let initial = { next_ticket = 1L; awaiting = None; job = None }
  let maximum_text_bytes = 256 * 1024
  let fail t message = { t with awaiting = None; job = None }, [ Failed message ]

  let read t job query result =
    let ticket = t.next_ticket in
    ( { next_ticket = Int64.succ ticket; awaiting = Some ticket; job = Some job }
    , [ Read (ticket, query, result) ] )
  ;;

  let frame parent depth =
    { parent
    ; depth
    ; cursor = None
    ; revision = None
    ; cursors = Rrbvec.empty
    ; gathered = Rrbvec.empty
    ; gathered_bytes = 0
    ; remaining = None
    }
  ;;

  let read_children t job current =
    read t job
      (Worker.Child_members { parent = current.parent; revision = None; after = current.cursor })
      (fun children -> Children_result children)
  ;;

  let add_text job text =
    let bytes = job.bytes + String.length text in
    if bytes > maximum_text_bytes
    then Error "The selected block is too large to copy."
    else if not (Journal_validation.is_valid_utf_8 text)
    then Error "The block text is invalid."
    else Ok { job with bytes; fragments = Rrbvec.push_back job.fragments text }
  ;;

  let child_text depth source =
    let indent = String.make (2 * depth) ' ' in
    "\n"
    ^ indent
    ^ "- "
    ^ String.concat ("\n" ^ indent ^ "  ") (String.split_on_char '\n' source)
  ;;

  let rec advance t job =
    match job.frames with
    | [] -> read t { job with phase = After } Worker.Graph_info (fun info -> Info_result info)
    | current :: parents ->
      (match current.remaining with
       | None -> read_children t { job with phase = Children } current
       | Some index when index >= Rrbvec.length current.gathered ->
         advance t { job with frames = parents }
       | Some index ->
         let child = Rrbvec.nth current.gathered index in
         if current.depth > maximum_text_bytes / 2
         then fail t "The selected outline is too deep to copy."
         else (
           match
             add_text job (child_text current.depth child.Protocol.value.block.title)
           with
           | Error message -> fail t message
           | Ok job ->
             let next = frame child.value.block.uuid (current.depth + 1) in
             read_children
               t
               { job with
                 phase = Children
               ; frames = next :: { current with remaining = Some (index + 1) } :: parents
               }
               next))
  ;;

  let complete t job outcome =
    match job.phase, outcome with
    | Before, Info_result info ->
      read
        t
        { job with
          phase = Root
        ; version = Some (info.graph_uuid, info.generation, info.projection_revision)
        }
        (Worker.Outline_block { uuid = job.root; revision = None })
        (fun block -> Block_result block)
    | Root, Block_result (V2_present_block { value; _ })
      when Graph.Uuid.equal value.block.uuid job.root ->
      (match add_text job value.block.title with
       | Error message -> fail t message
       | Ok job ->
         let current = frame job.root 1 in
         read_children
           t
           { job with
             page = Some value.block.page
           ; phase = Children
           ; frames = [ current ]
           }
           current)
    | Root, Block_result (V2_missing_block { uuid; _ })
      when Graph.Uuid.equal uuid job.root ->
      read t { job with phase = Page_root }
        (Worker.Page { uuid = job.root; revision = None }) (fun page -> Page_result page)
    | Page_root, Page_result (V2_present_page { page; _ })
      when Graph.Uuid.equal page.uuid job.root && not page.recycled ->
      (match add_text job page.title with
       | Error message -> fail t message
       | Ok job ->
         let current = frame job.root 1 in
         read_children
           t
           { job with page = Some page.uuid; phase = Children; frames = [ current ] }
           current)
    | Page_root, Page_result _ -> fail t "The selected page is unavailable."
    | Children, Children_result result ->
      (match job.frames with
       | current :: parents
         when Graph.Uuid.equal current.parent result.parent
              && result.revision_scope = Protocol.V2_children_revision current.parent
              && (current.revision = None || current.revision = Some result.scope_revision)
         ->
         let rec validate visited = function
           | [] -> Some visited
           | (child : Protocol.v2_child_member) :: rest ->
             let id = Graph.Uuid.to_string child.value.block.uuid in
             if
               Keys.mem id visited
               || (not (Graph.Uuid.equal child.value.block.parent current.parent))
               || Some child.value.block.page <> job.page
             then None
             else validate (Keys.add id visited) rest
         in
         (match validate job.visited result.items with
          | None -> fail t "The selected outline changed or contains invalid children."
          | Some visited ->
            let gathered = Rrbvec.append current.gathered (Rrbvec.of_list result.items) in
            let gathered_bytes =
              current.gathered_bytes
              + List.fold_left
                  (fun n (child : Protocol.v2_child_member) ->
                     n + String.length (child_text current.depth child.value.block.title))
                  0
                  result.items
            in
            if job.bytes + gathered_bytes > maximum_text_bytes
            then fail t "The selected block is too large to copy."
            else (
              match result.next with
              | Some cursor
                when Rrbvec.fold_left
                       (fun found previous -> found || previous = cursor)
                       false
                       current.cursors -> fail t "The child continuation did not advance."
              | Some cursor ->
                let current =
                  { current with
                    cursor = Some cursor
                  ; revision = Some result.scope_revision
                  ; cursors = Rrbvec.push_back current.cursors cursor
                  ; gathered
                  ; gathered_bytes
                  }
                in
                read_children t { job with visited; frames = current :: parents } current
              | None ->
                let current =
                  { current with gathered; gathered_bytes; remaining = Some 0 }
                in
                advance t { job with visited; frames = current :: parents }))
       | _ -> fail t "The selected outline changed while copying.")
    | After, Info_result info
      when job.version = Some (info.graph_uuid, info.generation, info.projection_revision)
      ->
      let buffer = Buffer.create job.bytes in
      Rrbvec.iter (Buffer.add_string buffer) job.fragments;
      let text = Buffer.contents buffer in
      (match Journal_platform.copy_text_request ~text with
       | Ok _ -> { t with awaiting = None; job = None }, [ Copied text ]
       | Error _ -> fail t "The selected block is too large to copy.")
    | Root, Block_result (V2_missing_block _) ->
      fail t "The selected block no longer exists."
    | _ -> fail t "The graph changed or returned an unexpected copy result. Try again."
  ;;

  let step t = function
    | Cancel -> { t with awaiting = None; job = None }, []
    | Start root ->
      let job =
        { root
        ; page = None
        ; version = None
        ; phase = Before
        ; frames = []
        ; visited = Keys.singleton (Graph.Uuid.to_string root)
        ; fragments = Rrbvec.empty
        ; bytes = 0
        }
      in
      read t job Worker.Graph_info (fun info -> Info_result info)
    | Completed (ticket, outcome) when t.awaiting = Some ticket ->
      (match t.job with
       | Some job -> complete t job outcome
       | None -> t, [])
    | Read_failed (ticket, message) when t.awaiting = Some ticket ->
      fail t ("Unable to copy block: " ^ message)
    | Completed _ | Read_failed _ -> t, []
  ;;
end

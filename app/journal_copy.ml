module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

module Keys = Set.Make (String)

type frame =
  { parent : Graph.Uuid.t
  ; depth : int
  ; cursor : Graph.Cursor.t option
  ; revision : string option
  ; cursors : Keys.t
  ; gathered_rev : Protocol.v2_child_member list
  ; remaining : Protocol.v2_child_member list option
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
  ; fragments_rev : string list
  ; bytes : int
  }

type t =
  { next_ticket : int64
  ; awaiting : int64 option
  ; job : job option
  }

type event =
  | Start of Graph.block_uuid
  | Completed of int64 * Protocol.v2_outcome
  | Read_failed of int64 * string
  | Cancel

type output_action =
  | Read of int64 * Protocol.command
  | Copied of string
  | Failed of string

let initial = { next_ticket = 1L; awaiting = None; job = None }
let maximum_text_bytes = 256 * 1024
let fail t message = { t with awaiting = None; job = None }, [ Failed message ]

let read t job command =
  let ticket = t.next_ticket in
  ( { next_ticket = Int64.succ ticket; awaiting = Some ticket; job = Some job }
  , [ Read (ticket, command) ] )
;;

let frame parent depth =
  { parent
  ; depth
  ; cursor = None
  ; revision = None
  ; cursors = Keys.empty
  ; gathered_rev = []
  ; remaining = None
  }
;;

let read_children t job current =
  read
    t
    job
    (Protocol.V2_get_children
       { parent = current.parent
       ; limit = Protocol.maximum_page_size
       ; cursor = current.cursor
       ; revision = None
       })
;;

let add_text job text =
  let bytes = job.bytes + String.length text in
  if bytes > maximum_text_bytes
  then Error "The selected block is too large to copy."
  else if not (Journal_validation.is_valid_utf_8 text)
  then Error "The block text is invalid."
  else Ok { job with bytes; fragments_rev = text :: job.fragments_rev }
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
  | [] -> read t { job with phase = After } Protocol.V2_graph_info
  | current :: parents ->
    (match current.remaining with
     | None -> read_children t { job with phase = Children } current
     | Some [] -> advance t { job with frames = parents }
     | Some (child :: rest) ->
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
             ; frames = next :: { current with remaining = Some rest } :: parents
             }
             next))
;;

let complete t job outcome =
  match job.phase, outcome with
  | Before, Protocol.V2_graph_info_outcome info ->
    read
      t
      { job with
        phase = Root
      ; version = Some (info.graph_uuid, info.generation, info.projection_revision)
      }
      (Protocol.V2_get_outline_block { block = job.root; revision = None })
  | Root, V2_block_outcome (V2_present_block { value; _ })
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
  | Root, V2_block_outcome (V2_missing_block {uuid;_}) when Graph.Uuid.equal uuid job.root ->
    read t {job with phase=Page_root} (Protocol.V2_get_page {page=job.root;revision=None})
  | Page_root, V2_page_outcome (V2_present_page {page;_})
    when Graph.Uuid.equal page.uuid job.root && not page.recycled ->
    (match add_text job page.title with
     | Error message -> fail t message
     | Ok job -> let current=frame job.root 1 in
       read_children t {job with page=Some page.uuid;phase=Children;frames=[current]} current)
  | Page_root, V2_page_outcome _ -> fail t "The selected page is unavailable."
  | Children, V2_children_outcome result ->
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
          let gathered_rev = List.rev_append result.items current.gathered_rev in
          (match result.next_cursor with
           | Some cursor when Keys.mem (Graph.Cursor.to_string cursor) current.cursors
             -> fail t "The child continuation did not advance."
           | Some cursor ->
             let current =
               { current with
                 cursor = Some cursor
               ; revision = Some result.scope_revision
               ; cursors = Keys.add (Graph.Cursor.to_string cursor) current.cursors
               ; gathered_rev
               }
             in
             read_children t { job with visited; frames = current :: parents } current
           | None ->
             let current =
               { current with
                 gathered_rev = []
               ; remaining = Some (List.rev gathered_rev)
               }
             in
             advance t { job with visited; frames = current :: parents }))
     | _ -> fail t "The selected outline changed while copying.")
  | After, V2_graph_info_outcome info
    when job.version = Some (info.graph_uuid, info.generation, info.projection_revision)
    ->
    let text = String.concat "" (List.rev job.fragments_rev) in
    (match Journal_platform.copy_text_request ~text with
     | Ok _ -> { t with awaiting = None; job = None }, [ Copied text ]
     | Error _ -> fail t "The selected block is too large to copy.")
  | _, V2_failed { message; _ } -> fail t ("Unable to copy block: " ^ message)
  | Root, V2_block_outcome (V2_missing_block _) ->
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
      ; fragments_rev = []
      ; bytes = 0
      }
    in
    read t job Protocol.V2_graph_info
  | Completed (ticket, outcome) when t.awaiting = Some ticket ->
    (match t.job with
     | Some job -> complete t job outcome
     | None -> t, [])
  | Read_failed (ticket, message) when t.awaiting = Some ticket ->
    fail t ("Unable to copy block: " ^ message)
  | Completed _ | Read_failed _ -> t, []
;;

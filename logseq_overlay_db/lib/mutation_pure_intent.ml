module Graph = Logseq_db_types.Graph_types
module U = Graph.Uuid
module J = Persistence_json

let ( let* ) = Result.bind

type precondition =
  { blocks : (U.t * Types.block_state_revision) list
  ; pages : (U.t * Types.page_state_revision) list
  ; scopes : (Types.structure_revision_scope * Types.scope_revision) list
  }

type t =
  { namespace : string
  ; graph_uuid : U.t
  ; mutation_id : U.t
  ; payload : string
  ; expected : precondition
  ; mutation : Types.local_mutation
  ; encoded : string
  ; targets : U.t Rrbvec.t
  }

type commit =
  { intent : t
  ; outcome : Types.local_commit
  ; encoded : string
  }

type expected_wire =
  { blocks : (string * string) list
  ; pages : (string * string) list
  ; scopes : (string * string) list
  }
[@@deriving yojson]

type intent_wire =
  { version : int
  ; namespace : string
  ; graph_uuid : string
  ; mutation_id : string
  ; payload : string
  ; expected : expected_wire
  ; mutation :
      (Types.local_mutation
      [@to_yojson Persistence_outbox_v16.mutation_to_yojson]
      [@of_yojson Persistence_outbox_v16.mutation_of_yojson])
  }
[@@deriving yojson]

type interest_wire =
  | Children of string
  | Tree of string
  | Journals
[@@deriving yojson]

type summary_wire =
  | No_change
  | Exact of string list * string list * interest_wire list
  | Resync of string
[@@deriving yojson]

type commit_wire =
  { version : int
  ; fingerprint : string
  ; mutation_id : string
  ; status : J.local_status
  ; generation : string
  ; before : string
  ; after : string
  ; summary : summary_wire
  }
[@@deriving yojson]

let canonical json = Yojson.Safe.to_string (Yojson.Safe.sort json)

let fingerprint (intent : t) =
  Digestif.SHA256.digest_string intent.encoded |> Digestif.SHA256.to_hex
;;

let bounded maximum source = String.length source > 0 && String.length source <= maximum

let namespace_valid source =
  String.length source = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       source
;;

let targets = function
  | Types.Append_journal{root;_} ->
    Overlay_planner.append_nodes root |> Rrbvec.map(fun (node:Types.append_node)->node.uuid)
    |> Rrbvec.sort_uniq U.compare
  | Types.Insert_blocks { tree; _ } ->
    let nodes = ref (Rrbvec.singleton tree)
    and found = ref Rrbvec.empty
    and index = ref 0 in
    while !index < Rrbvec.length !nodes do
      let node = Rrbvec.nth !nodes !index in
      found := Rrbvec.push_back !found node.Types.uuid;
      nodes := List.fold_left Rrbvec.push_back !nodes node.children;
      incr index
    done;
    Rrbvec.sort_uniq U.compare !found
  | Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ }
  | Set_asset_reference { block; _ }
  | Publish_asset { block; _ } -> Rrbvec.singleton block
  | Delete_blocks { root; _ } -> Rrbvec.singleton root
  | Create_journal_page { page; _ } -> Rrbvec.singleton page
;;

let expected_wire (expected : precondition) =
  let pairs render entries =
    List.map (fun (id, revision) -> U.to_string id, render revision) entries
    |> List.sort compare
  in
  { blocks = pairs Types.Block_state_revision.to_string expected.blocks
  ; pages = pairs Types.Page_state_revision.to_string expected.pages
  ; scopes =
      List.map
        (fun (Types.Children_revision parent, revision) ->
           U.to_string parent, Types.Scope_revision.to_string revision)
        expected.scopes
      |> List.sort compare
  }
;;

let create ~namespace ~graph_uuid ~payload ~(expected : precondition) mutation =
  let valid_pairs entries =
    List.length entries <= 256
    && List.length (List.sort_uniq (fun (a, _) (b, _) -> compare a b) entries)
       = List.length entries
  in
  if
    (not (namespace_valid namespace))
    || not (bounded Logseq_db_types.Limits.maximum_request_bytes payload)
  then Error "Invalid durable intent namespace or payload bounds"
  else if
    not
      (valid_pairs expected.blocks
       && valid_pairs expected.pages
       && valid_pairs expected.scopes)
  then Error "Invalid durable intent read set"
  else
    let* () = Overlay_planner.validate mutation in
    let mutation_id = Overlay_planner.mutation_id mutation in
    let wire =
      { version = 1
      ; namespace
      ; graph_uuid = U.to_string graph_uuid
      ; mutation_id = U.to_string mutation_id
      ; payload
      ; expected = expected_wire expected
      ; mutation
      }
    in
    let encoded = canonical (intent_wire_to_yojson wire) in
    if not (bounded 2097152 encoded)
    then Error "Complete durable intent exceeds storage budget"
    else
      Ok
        { namespace
        ; graph_uuid
        ; mutation_id
        ; payload
        ; expected
        ; mutation
        ; encoded
        ; targets = targets mutation
        }
;;

let rec map_result f = function
  | [] -> Ok []
  | value :: rest ->
    let* value = f value in
    let* rest = map_result f rest in
    Ok (value :: rest)
;;

let decode ~namespace ~graph_uuid encoded =
  try
    if not (bounded 2097152 encoded)
    then Error "Invalid stored intent bounds"
    else
      let* wire = intent_wire_of_yojson (Yojson.Safe.from_string encoded) in
      if
        wire.version <> 1
        || wire.namespace <> namespace
        || wire.graph_uuid <> U.to_string graph_uuid
        || wire.mutation_id <> U.to_string (Overlay_planner.mutation_id wire.mutation)
      then Error "Stored intent identity does not match its logical owner"
      else (
        let pairs parse values =
          map_result
            (fun (id, revision) ->
               let* id = U.of_string id in
               let* revision = parse revision in
               Ok (id, revision))
            values
        in
        let* blocks = pairs Types.Block_state_revision.of_string wire.expected.blocks in
        let* pages = pairs Types.Page_state_revision.of_string wire.expected.pages in
        let* scopes = pairs Types.Scope_revision.of_string wire.expected.scopes in
        let scopes =
          List.map
            (fun (parent, revision) -> Types.Children_revision parent, revision)
            scopes
        in
        let* intent =
          create
            ~namespace
            ~graph_uuid
            ~payload:wire.payload
            ~expected:{ blocks; pages; scopes }
            wire.mutation
        in
        if intent.encoded <> encoded
        then Error "Stored intent is not canonical"
        else Ok intent)
  with
  | exn -> Error (Printexc.to_string exn)
;;

let resync_wire = function
  | Types.Change_limit_exceeded -> "changeLimit"
  | Dispatcher_retention_exceeded -> "retention"
  | Generation_changed -> "generation"
  | Publication_recovered -> "publication"
;;

let resync_decode = function
  | "changeLimit" -> Ok Types.Change_limit_exceeded
  | "retention" -> Ok Types.Dispatcher_retention_exceeded
  | "generation" -> Ok Types.Generation_changed
  | "publication" -> Ok Types.Publication_recovered
  | _ -> Error "Unknown stored resync reason"
;;

let summary_wire = function
  | Types.No_logical_change -> No_change
  | Logical_resync_required reason -> Resync (resync_wire reason)
  | Exact_logical_change { block_uuids; page_uuids; structure_interests } ->
    Exact
      ( List.map U.to_string block_uuids
      , List.map U.to_string page_uuids
      , List.map
          (function
            | Types.Children_interest id -> Children (U.to_string id)
            | Page_tree_interest id -> Tree (U.to_string id)
            | Journal_index_interest -> Journals)
          structure_interests )
;;

let summary_decode = function
  | No_change -> Ok Types.No_logical_change
  | Resync reason ->
    Result.map (fun reason -> Types.Logical_resync_required reason) (resync_decode reason)
  | Exact (blocks, pages, interests) ->
    let* block_uuids = map_result U.of_string blocks in
    let* page_uuids = map_result U.of_string pages in
    let* structure_interests =
      map_result
        (function
          | Children id ->
            Result.map (fun id -> Types.Children_interest id) (U.of_string id)
          | Tree id -> Result.map (fun id -> Types.Page_tree_interest id) (U.of_string id)
          | Journals -> Ok Types.Journal_index_interest)
        interests
    in
    Ok (Types.Exact_logical_change { block_uuids; page_uuids; structure_interests })
;;

let committed (intent : t) (outcome : Types.local_commit) =
  if
    (not (U.equal intent.mutation_id outcome.mutation_id))
    || outcome.status = Types.Already_applied
  then Error "A replay/current revision cannot create original commit evidence"
  else (
    let wire =
      { version = 1
      ; fingerprint = fingerprint intent
      ; mutation_id = U.to_string outcome.mutation_id
      ; status = outcome.status
      ; generation = Types.Generation.to_string outcome.generation
      ; before = Types.Projection_revision.to_string outcome.before_projection_revision
      ; after = Types.Projection_revision.to_string outcome.after_projection_revision
      ; summary = summary_wire outcome.logical_change_summary
      }
    in
    let encoded = canonical (commit_wire_to_yojson wire) in
    if not (bounded 1048576 encoded)
    then Error "Original commit evidence exceeds storage budget"
    else Ok { intent; outcome; encoded })
;;

let decode_commit (intent : t) encoded =
  try
    if not (bounded 1048576 encoded)
    then Error "Invalid stored commit bounds"
    else
      let* wire = commit_wire_of_yojson (Yojson.Safe.from_string encoded) in
      if
        wire.version <> 1
        || wire.fingerprint <> fingerprint intent
        || wire.mutation_id <> U.to_string intent.mutation_id
      then Error "Stored commit does not match complete intent"
      else
        let* generation = Types.Generation.of_string wire.generation in
        let* before_projection_revision =
          Types.Projection_revision.of_string wire.before
        in
        let* after_projection_revision = Types.Projection_revision.of_string wire.after in
        let* logical_change_summary = summary_decode wire.summary in
        let* result =
          committed
            intent
            { Types.mutation_id = intent.mutation_id
            ; status = wire.status
            ; generation
            ; before_projection_revision
            ; after_projection_revision
            ; logical_change_summary
            }
        in
        if result.encoded <> encoded
        then Error "Stored commit is not canonical"
        else Ok result
  with
  | exn -> Error (Printexc.to_string exn)
;;

let rejection_code = function
  | Types.Invalid_local_mutation message ->
    Some (`List [ `String "invalid"; `String message ])
  | Mutation_identity_conflict -> Some (`List [ `String "identity" ])
  | Missing_precondition None -> Some (`List [ `String "missing" ])
  | Missing_precondition (Some (Children_revision parent)) ->
    Some (`List [ `String "missingChildren"; `String (U.to_string parent) ])
  | Target_precondition_conflict -> Some (`List [ `String "precondition" ])
  | Planner_limit_exceeded -> Some (`List [ `String "plannerLimit" ])
  | Delete_unsupported_for_footprint -> Some (`List [ `String "deleteFootprint" ])
  | Local_database_closed
  | Local_commit_busy
  | Local_commit_persistence_failed _
  | Local_commit_fatal_state _ -> None
;;

let rejection (intent : t) error =
  Option.map
    (fun code ->
       canonical
         (`Assoc
             [ "version", `Int 1
             ; "fingerprint", `String (fingerprint intent)
             ; "rejection", code
             ]))
    (rejection_code error)
;;

let decode_rejection (intent : t) encoded =
  try
    match Yojson.Safe.from_string encoded with
    | `Assoc fields when List.mem_assoc "rejection" fields ->
      let* error =
        match List.assoc "rejection" fields with
        | `List [ `String "invalid"; `String message ] ->
          Ok (Types.Invalid_local_mutation message)
        | `List [ `String "identity" ] -> Ok Types.Mutation_identity_conflict
        | `List [ `String "missing" ] -> Ok (Types.Missing_precondition None)
        | `List [ `String "missingChildren"; `String parent ] ->
          Result.map
            (fun parent ->
               Types.Missing_precondition (Some (Types.Children_revision parent)))
            (U.of_string parent)
        | `List [ `String "precondition" ] -> Ok Types.Target_precondition_conflict
        | `List [ `String "plannerLimit" ] -> Ok Types.Planner_limit_exceeded
        | `List [ `String "deleteFootprint" ] -> Ok Types.Delete_unsupported_for_footprint
        | _ -> Error "Invalid stored rejection"
      in
      if rejection intent error = Some encoded
      then Ok (Some error)
      else Error "Stored rejection does not match complete intent"
    | _ -> Ok None
  with
  | exn -> Error (Printexc.to_string exn)
;;

module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

type lookup = Page_lookup | Outline_lookup
type read = { block_id : string; depth : int; lookup : lookup }
type source =
  | Block of Graph.block
  | Missing_outline of Graph.Uuid.t
  | Page of { page : Graph.page; detail_owner : bool }
  | Missing_page of Graph.Uuid.t
type known = { id : string; text : string option; page_kind : bool }
type change =
  | Block_changed of { id : string; journal_block_known : bool }
  | Page_changed of { id : string; detail_page_owned : unit -> bool }
type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 option -> read -> Protocol.command -> Protocol.request
  ; known_page : string -> Graph.page option
  }
type output =
  { requests : Protocol.request Rrbvec.t
  ; updates : (string * string option) Rrbvec.t
  }
type reference_source = Source_text of string | Source_missing | Source_retryable
type t =
  { reference_sources : (string, int64 * reference_source) Hashtbl.t
  ; reference_pages : (string, unit) Hashtbl.t
  ; reference_depths : (string, int) Hashtbl.t
  ; reference_pending : (string, unit) Hashtbl.t
  ; reference_dirty : (string, unit) Hashtbl.t
  ; localtime : float -> Unix.tm
  }
let maximum_reference_targets = 4096
let maximum_reference_sources = 8192
let empty = { requests = Rrbvec.empty; updates = Rrbvec.empty }
let requests value = { empty with requests = Rrbvec.of_list value }
let create ~localtime () =
  { reference_sources = Hashtbl.create 64
  ; reference_pages = Hashtbl.create 64
  ; reference_depths = Hashtbl.create 64
  ; reference_pending = Hashtbl.create 64
  ; reference_dirty = Hashtbl.create 16
  ; localtime
  }
let reset t =
  Hashtbl.clear t.reference_sources;
  Hashtbl.clear t.reference_pages;
  Hashtbl.clear t.reference_depths;
  Hashtbl.clear t.reference_pending;
  Hashtbl.clear t.reference_dirty
;;

let reference_read ?(lookup = Page_lookup) ?source_epoch t ~ports block_id depth =
  if Hashtbl.mem t.reference_pending block_id
  then None
  else (
    Hashtbl.replace t.reference_pending block_id ();
    let uuid = Graph.Uuid.of_string block_id |> Result.get_ok in
    Some
      (ports.plan_read ~source_epoch { block_id; depth; lookup }
         (match lookup with
          | Page_lookup -> Protocol.V2_get_page { page = uuid; revision = None }
          | Outline_lookup ->
            Protocol.V2_get_outline_block { block = uuid; revision = None })))
;;

let fence t ~now block_id =
  match Hashtbl.find_opt t.reference_sources block_id with
  | Some _ ->
    (* The displayed value is retained by the model until a completion, but the
       invalidated runtime source must remain retryable if its read is abandoned. *)
    Hashtbl.replace t.reference_sources block_id (now (), Source_retryable)
  | None when Hashtbl.mem t.reference_depths block_id ->
    Hashtbl.replace t.reference_sources block_id (now (), Source_retryable)
  | None -> ()
;;

let invalidate_reference t ~ports block_id =
  fence t ~now:ports.now block_id;
  match Hashtbl.find_opt t.reference_depths block_id with
  | None -> None
  | Some depth ->
    if Hashtbl.mem t.reference_pending block_id
    then (
      Hashtbl.replace t.reference_dirty block_id ();
      None)
    else reference_read t ~ports block_id depth
;;

let reference_source t (block : Graph.block) =
  if String.trim block.title <> ""
  then block.title
  else
    List.find_map
      (fun (p : Graph.property_summary) ->
         if p.ident = "logseq.property/value"
         then (
           match
             Journal_model.property_sources
               ~localtime:t.localtime
               [ { p with schema = { p.schema with hidden = false } } ]
           with
           | (_, source) :: _ -> Some source
           | [] -> None)
         else None)
      block.properties
    |> Option.value ~default:block.title
;;

let reference_source_text = function
  | Source_text source -> Some source
  | Source_missing | Source_retryable -> None
;;

let reference_needs_read t id =
  match Hashtbl.find_opt t.reference_sources id with
  | None | Some (_, Source_retryable) -> true
  | Some (_, (Source_text _ | Source_missing)) -> false
;;

let observe_reference_sources
      ?(missing_is_final = false)
      ?(extra_sources = Seq.empty)
      ?(known_sources = Seq.empty)
      t
      ~ports
      ~source_epoch
      depth
      values
  =
  let updates = ref Rrbvec.empty
  and reads = ref Rrbvec.empty in
  (* Install the whole fragment before discovery. Epochs belong to request
     issuance, not completion order; revision strings are opaque. Advance the
     fence even when the title did not change. *)
  let values =
    Seq.fold_left
      (fun installed ((id, source) as value) ->
         let previous = Hashtbl.find_opt t.reference_sources id in
         if
           match previous with
           | Some (epoch, _) -> Int64.compare source_epoch epoch >= 0
           | None ->
             Hashtbl.mem t.reference_depths id
             || Hashtbl.length t.reference_sources < maximum_reference_sources
         then (
           let state = match source with
             | Some text -> Source_text text
             | None -> if missing_is_final then Source_missing else Source_retryable in
           Hashtbl.replace t.reference_sources id (source_epoch, state);
           if (Option.map (fun (_, state) -> reference_source_text state) previous <> Some source
              ||
              match previous with
              | Some (_, Source_retryable) -> true
              | _ -> false)
              && Hashtbl.mem t.reference_depths id
           then updates := Rrbvec.push_back !updates (id, source);
           Rrbvec.push_back installed value)
         else installed)
      Rrbvec.empty
      (Seq.append values known_sources)
  in
  let rec discover depth source =
    if depth < Journal_model.maximum_reference_depth
    then
      List.iter
        (fun id ->
           let next_depth = depth + 1 in
           let previous = Hashtbl.find_opt t.reference_depths id in
           if
             match previous with
             | Some old ->
               next_depth < old
               || (next_depth = old
                   && reference_needs_read t id
                   && not (Hashtbl.mem t.reference_pending id))
             | None -> Hashtbl.length t.reference_depths < maximum_reference_targets
           then (
             Hashtbl.replace t.reference_depths id next_depth;
             match Hashtbl.find_opt t.reference_sources id with
             | Some (_, Source_text source) ->
               updates := Rrbvec.push_back !updates (id, Some source);
               discover next_depth source
             | Some (_, Source_missing) -> updates := Rrbvec.push_back !updates (id, None)
             | Some (_, Source_retryable) | None ->
               Option.iter
                 (fun request -> reads := Rrbvec.push_back !reads request)
                 (reference_read t ~ports id next_depth)))
        (Journal_model.reference_ids source)
  in
  Rrbvec.iter (fun (_, source) -> Option.iter (discover depth) source) values;
  Seq.iter (discover depth) extra_sources;
  { requests = !reads; updates = !updates }
;;

let complete_reference_read t ~ports ~source_epoch ~block_id ~depth source =
  let depth =
    Hashtbl.find_opt t.reference_depths block_id |> Option.value ~default:depth
  in
  Hashtbl.remove t.reference_pending block_id;
  if Hashtbl.mem t.reference_dirty block_id
  then (
    Hashtbl.remove t.reference_dirty block_id;
    requests (Option.to_list (reference_read t ~ports block_id depth)))
  else observe_reference_sources ~missing_is_final:true t ~ports ~source_epoch depth (Seq.return (block_id, source))
;;

let reference_is_current t ~source_epoch block_id =
  match Hashtbl.find_opt t.reference_sources block_id with
  | Some (epoch, _) -> Int64.compare source_epoch epoch >= 0
  | None -> true
;;

let read_failed t ~ports ~source_epoch ~block_id ~depth =
  Hashtbl.remove t.reference_pending block_id;
  if Hashtbl.mem t.reference_dirty block_id
  then (
    Hashtbl.remove t.reference_dirty block_id;
    requests (Option.to_list (reference_read t ~ports block_id depth)))
  else if reference_is_current t ~source_epoch block_id
  then (
    (* A failed/cancelled read is retryable, not proof of target absence. *)
    Hashtbl.replace t.reference_sources block_id (source_epoch, Source_retryable);
    { empty with updates = Rrbvec.singleton (block_id, None) })
  else empty
;;

let continue_reference_outline t ~ports ~source_epoch ~block_id ~depth =
  Hashtbl.remove t.reference_pending block_id;
  if Hashtbl.mem t.reference_dirty block_id
  then (
    Hashtbl.remove t.reference_dirty block_id;
    requests (Option.to_list (reference_read t ~ports block_id depth)))
  else if reference_is_current t ~source_epoch block_id
  then
    (* Both stages belong to the original snapshot observation. A newer
       fragment must fence the fallback even though its request id is newer. *)
    requests
      (Option.to_list
         (reference_read ~lookup:Outline_lookup ~source_epoch t ~ports block_id depth))
  else empty
;;

let plan_change t ~ports = function
  | Block_changed { id; journal_block_known = false } -> invalidate_reference t ~ports id
  | Block_changed { id; journal_block_known = true } ->
    if Hashtbl.mem t.reference_pending id then Hashtbl.replace t.reference_dirty id ();
    None
  | Page_changed { id; detail_page_owned } ->
    if Hashtbl.mem t.reference_depths id then
      if detail_page_owned () then (
        if Hashtbl.mem t.reference_pending id then Hashtbl.replace t.reference_dirty id ();
        None)
      else invalidate_reference t ~ports id
    else None
;;
let resync t ~ports =
  Hashtbl.to_seq_keys t.reference_depths
  |> Seq.filter_map (invalidate_reference t ~ports)
  |> Seq.fold_left Rrbvec.push_back Rrbvec.empty
;;
let shared_read_failed t ~ports ~source_epoch ~block_id =
  if Hashtbl.mem t.reference_depths block_id then
    observe_reference_sources t ~ports ~source_epoch 0 (Seq.return (block_id, None))
  else empty
;;
let receive_page t ~ports ~source_epoch (read : read) lookup =
  let { block_id; depth; _ } = read in
  match lookup with
  | Protocol.V2_missing_page _ ->
    continue_reference_outline t ~ports ~source_epoch ~block_id ~depth
  | V2_present_page { page; _ } ->
    (* Own reads intentionally do not share the common observer's capacity gate. *)
    if reference_is_current t ~source_epoch block_id
       && not (Hashtbl.mem t.reference_dirty block_id)
    then Hashtbl.replace t.reference_pages block_id ();
    if page.recycled then read_failed t ~ports ~source_epoch ~block_id ~depth
    else complete_reference_read t ~ports ~source_epoch ~block_id ~depth (Some page.title)
;;
let receive_outline t ~ports ~source_epoch (read : read) lookup =
  let source = match lookup with
    | Protocol.V2_present_block { value; _ } -> Some (reference_source t value.block)
    | V2_missing_block _ -> None in
  complete_reference_read t ~ports ~source_epoch ~block_id:read.block_id ~depth:read.depth source
;;

let observe_fragment t ~ports ~source_epoch ~sources ~changes ~property_blocks =
  let values = Rrbvec.fold_left
    (fun values -> function
      | Block block -> Rrbvec.push_back values
          (Graph.Uuid.to_string block.uuid, Some (reference_source t block))
      | Missing_outline uuid ->
        let id = Graph.Uuid.to_string uuid in
        if Hashtbl.mem t.reference_pages id then values
        else Rrbvec.push_back values (id, None)
      | Page { page; detail_owner } ->
        let id = Graph.Uuid.to_string page.uuid in
        if Hashtbl.mem t.reference_pages id || detail_owner then (
          if Hashtbl.length t.reference_pages < maximum_reference_targets
          then Hashtbl.replace t.reference_pages id ();
          Rrbvec.push_back values (id, if page.recycled then None else Some page.title))
        else values
      | Missing_page uuid ->
        let id = Graph.Uuid.to_string uuid in
        if Hashtbl.mem t.reference_pages id then Rrbvec.push_back values (id, None)
        else values)
    Rrbvec.empty sources in
  let values = Rrbvec.fold_left
    (fun values { id; text; page_kind } ->
      if page_kind && Hashtbl.length t.reference_pages < maximum_reference_targets
      then Hashtbl.replace t.reference_pages id ();
      Rrbvec.push_front values (id, text))
    values changes in
      let known_pages = ref Rrbvec.empty in
      let seen_pages = Hashtbl.create 16 in
      let extra_sources =
        Seq.flat_map
          (fun (block : Graph.block) ->
             List.iter
               (fun (p : Graph.property_summary) ->
                  if
                    (not p.schema.hidden)
                    && p.ident <> "block/tags"
                    && p.ident <> "logseq.property/status"
                  then
                    List.iter
                      (function
                        | Graph.Page_value uuid | Class_value uuid ->
                          let id = Graph.Uuid.to_string uuid in
                          if
                            Hashtbl.mem t.reference_pages id
                            || Hashtbl.length t.reference_pages
                               < maximum_reference_targets
                          then (
                            let new_page_kind = not (Hashtbl.mem t.reference_pages id) in
                            Hashtbl.replace t.reference_pages id ();
                            if new_page_kind then (
                              (* A generic block miss is not a page miss. Reset
                                 discovery once when semantic metadata refines
                                 the lookup kind, fencing an older in-flight read. *)
                              (match Hashtbl.find_opt t.reference_sources id with
                               | Some (epoch, (Source_missing | Source_retryable)) ->
                                 Hashtbl.replace t.reference_sources id
                                   (Int64.max epoch source_epoch, Source_retryable)
                               | Some (_, Source_text _) | None -> ());
                              if Hashtbl.mem t.reference_pending id then
                                Hashtbl.replace t.reference_dirty id ());
                            if
                              not
                                (Hashtbl.mem t.reference_sources id
                                 || Hashtbl.mem seen_pages id)
                            then (
                              Hashtbl.replace seen_pages id ();
                              Option.iter
                                (fun (page : Graph.page) ->
                                   known_pages
                                   := Rrbvec.push_back
                                        !known_pages
                                        ( id
                                        , if page.recycled then None else Some page.title
                                        ))
                                (ports.known_page id)))
                        | _ -> ())
                      p.values)
               block.properties;
             Journal_model.property_sources ~localtime:t.localtime block.properties
             |> List.to_seq
             |> Seq.map snd)
          property_blocks
        |> Seq.fold_left
             (fun sources source -> Rrbvec.push_back sources source)
             Rrbvec.empty
        |> Rrbvec.to_seq
      in
      observe_reference_sources
        ~extra_sources
        ~known_sources:(Rrbvec.to_seq !known_pages)
        t
        ~ports
        ~source_epoch
        0
        (Rrbvec.to_seq values)

;;
let abandon t ~source_epoch (read : read) =
  Hashtbl.remove t.reference_pending read.block_id;
  Hashtbl.remove t.reference_dirty read.block_id;
  if reference_is_current t ~source_epoch read.block_id then
    Hashtbl.replace t.reference_sources read.block_id (source_epoch, Source_retryable)
;;

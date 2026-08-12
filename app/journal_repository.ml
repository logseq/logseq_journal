open Datascript

module Error = struct
  type oversized_source =
    { block_id : string
    ; measured_bytes : int
    }

  type t =
    | Message of string
    | Stored_source of oversized_source

  let to_string = function
    | Message message -> message
    | Stored_source value ->
      Printf.sprintf
        "stored block %s exceeds 65,536 UTF-8 bytes (%d bytes)"
        value.block_id
        value.measured_bytes
  ;;

  let oversized_source = function
    | Stored_source value -> Some value
    | Message _ -> None
  ;;
end

let error message = Error (Error.Message message)

type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t

type capture =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type capture_plan =
  | Already_applied of block
  | Apply of Datascript.tx_op list

type create_child =
  { mutation_id : string
  ; block_id : string
  ; parent_block_id : string
  ; expected_parent_revision : int
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type create_child_plan =
  | Child_already_applied of block
  | Create_child of Datascript.tx_op list

type update_source =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; source : string
  }

type set_task_state =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; task_state : Journal_model.task_state
  }

type update_plan =
  | Update_already_applied of block
  | Update_conflict of block
  | Update_block of Datascript.tx_op list

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  }

type delete_subtree_plan =
  | Delete_already_applied
  | Delete_conflict of block
  | Delete_subtree of
      { transaction : Datascript.tx_op list
      ; deleted_count : int
      ; parent_block_id : string option
      }

type day_feed =
  { page : page
  ; blocks : block list
  ; has_more_blocks : bool
  }

type feed =
  { days : day_feed list
  ; slot_count : int
  ; has_more_days : bool
  }

type block_cursor =
  { after_sibling_order : string
  ; after_block_id : string
  }

type block_page =
  { blocks : block list
  ; continuation : block_cursor option
  }

type detail =
  { root : block
  ; children : block_page
  }

let initialize_store_transaction () =
  [ Add
      ( Temp_id "journal-store"
      , Journal_schema.Attr.store_id
      , String Journal_schema.store_identity )
  ; Add
      ( Temp_id "journal-store"
      , Journal_schema.Attr.store_schema_version
      , Int Journal_schema.version )
  ]
;;

let datoms_for_attribute db attribute =
  Datascript.datoms db Avet ~a:attribute ()
  |> Seq.take_while (fun datom -> String.equal datom.a attribute)
  |> List.of_seq
;;

let validate_store db =
  match Journal_schema.validate_schema db.schema with
  | Error schema_error -> error (Journal_schema.Error.to_string schema_error)
  | Ok () ->
    (match
       ( datoms_for_attribute db Journal_schema.Attr.store_id
       , datoms_for_attribute db Journal_schema.Attr.store_schema_version )
     with
     | [ { v = String identity; _ } ], [ { v = Int version; _ } ]
       when String.equal identity Journal_schema.store_identity
            && version = Journal_schema.version -> Ok ()
     | _ -> error "store identity or schema version is invalid")
;;

let one_value datoms attribute =
  datoms
  |> List.filter_map (fun datom ->
    if String.equal datom.a attribute then Some datom.v else None)
  |> function
  | [ value ] -> Ok value
  | [] -> error ("missing required entity attribute: " ^ attribute)
  | _ -> error ("duplicate entity attribute: " ^ attribute)
;;

let keyword_of_task_state = function
  | Journal_model.Not_a_task -> "not-a-task"
  | Todo -> "todo"
  | Done -> "done"
;;

let task_state_of_keyword = function
  | "not-a-task" -> Ok Journal_model.Not_a_task
  | "todo" -> Ok Todo
  | "done" -> Ok Done
  | _ -> error "block has an unsupported task state"
;;

let page_for_entity db entity_id =
  let datoms = Datascript.datoms db Eavt ~e:entity_id () |> List.of_seq in
  match
    ( one_value datoms Journal_schema.Attr.page_id
    , one_value datoms Journal_schema.Attr.page_day
    , one_value datoms Journal_schema.Attr.page_title )
  with
  | Ok (Uuid id), Ok (Int day), Ok (String title) -> Ok { id; day; title }
  | Ok _, Ok _, Ok _ -> error "journal page attributes have invalid value types"
  | (Error _ as result), _, _ | _, (Error _ as result), _ | _, _, (Error _ as result) ->
    result
;;

let parent_id_for_entity db ~page_entity parent_entity =
  if parent_entity = page_entity
  then Ok None
  else (
    match
      Datascript.datoms db Eavt ~e:parent_entity ~a:Journal_schema.Attr.block_id ()
      |> List.of_seq
    with
    | [ { v = Uuid parent_id; _ } ] -> Ok (Some parent_id)
    | _ -> error "block parent does not have one stable block ID")
;;

let child_count_for_entity db entity_id =
  let count value =
    Datascript.datoms db Avet ~a:Journal_schema.Attr.block_parent ~v:value ()
    |> Seq.length
  in
  let reference_count = count (Ref entity_id) in
  if reference_count > 0 then reference_count else count (Int entity_id)
;;

let find_block db ~id =
  if not (Journal_validation.is_uuid id)
  then error "Journal block ID must be a UUID"
  else (
    match Datascript.entid db Journal_schema.Attr.block_id (Uuid id) with
    | None -> Ok None
    | Some entity_id ->
      let datoms = Datascript.datoms db Eavt ~e:entity_id () |> List.of_seq in
      (match
         ( one_value datoms Journal_schema.Attr.block_id
         , one_value datoms Journal_schema.Attr.block_page
         , one_value datoms Journal_schema.Attr.block_parent
         , one_value datoms Journal_schema.Attr.block_order
         , one_value datoms Journal_schema.Attr.block_source
         , one_value datoms Journal_schema.Attr.block_task_state
         , one_value datoms Journal_schema.Attr.block_created_instant_unix_ms
         , one_value datoms Journal_schema.Attr.block_created_local_day
         , one_value datoms Journal_schema.Attr.block_created_local_minute
         , one_value datoms Journal_schema.Attr.block_created_time_zone_id
         , one_value datoms Journal_schema.Attr.block_created_utc_offset_seconds
         , one_value datoms Journal_schema.Attr.block_revision
         , one_value datoms Journal_schema.Attr.block_last_mutation_id )
       with
       | ( Ok (Uuid actual_id)
         , Ok (Ref page_entity)
         , Ok (Ref parent_entity)
         , Ok (String sibling_order)
         , Ok (String source)
         , Ok (Keyword task_keyword)
         , Ok (Int instant_unix_ms)
         , Ok (Int local_day)
         , Ok (Int local_minute_of_day)
         , Ok (String time_zone_id)
         , Ok (Int utc_offset_seconds)
         , Ok (Int revision)
         , Ok (Uuid last_mutation_id) ) ->
         if String.length source > 65_536
         then
           Error
             (Error.Stored_source
                { block_id = actual_id; measured_bytes = String.length source })
         else (
           match
             ( page_for_entity db page_entity
             , parent_id_for_entity db ~page_entity parent_entity
             , task_state_of_keyword task_keyword
             , Journal_time.create
                 ~instant_unix_ms:(Int64.of_int instant_unix_ms)
                 ~local_day
                 ~local_minute_of_day
                 ~time_zone_id
                 ~utc_offset_seconds )
           with
           | Ok page, Ok parent_id, Ok task_state, Ok creation_time ->
             (match
                Journal_model.create
                  ~id:actual_id
                  ~page_id:page.id
                  ~journal_day:page.day
                  ~parent_id
                  ~sibling_order
                  ~source
                  ~task_state
                  ~child_count:(child_count_for_entity db entity_id)
                  ~creation_time
                  ~revision
                  ~last_mutation_id
              with
              | Ok block -> Ok (Some block)
              | Error message -> error message)
           | (Error _ as result), _, _, _
           | _, (Error _ as result), _, _
           | _, _, (Error _ as result), _ -> result
           | _, _, _, Error message -> error message)
       | Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _, Ok _ ->
         error "Journal block attributes have invalid value types"
       | (Error _ as result), _, _, _, _, _, _, _, _, _, _, _, _
       | _, (Error _ as result), _, _, _, _, _, _, _, _, _, _, _
       | _, _, (Error _ as result), _, _, _, _, _, _, _, _, _, _
       | _, _, _, (Error _ as result), _, _, _, _, _, _, _, _, _
       | _, _, _, _, (Error _ as result), _, _, _, _, _, _, _, _
       | _, _, _, _, _, (Error _ as result), _, _, _, _, _, _, _
       | _, _, _, _, _, _, (Error _ as result), _, _, _, _, _, _
       | _, _, _, _, _, _, _, (Error _ as result), _, _, _, _, _
       | _, _, _, _, _, _, _, _, (Error _ as result), _, _, _, _
       | _, _, _, _, _, _, _, _, _, (Error _ as result), _, _, _
       | _, _, _, _, _, _, _, _, _, _, (Error _ as result), _, _
       | _, _, _, _, _, _, _, _, _, _, _, (Error _ as result), _
       | _, _, _, _, _, _, _, _, _, _, _, _, (Error _ as result) -> result))
;;

let validate_identity name value =
  if Journal_validation.is_uuid value then Ok () else error (name ^ " must be a UUID")
;;

let validate_sibling_order value =
  if
    String.equal value ""
    || String.length value > 512
    || (not (Journal_validation.is_valid_utf_8 value))
    || Journal_validation.contains_nul value
  then error "sibling order is invalid"
  else Ok ()
;;

let validate_new_block ~mutation_id ~block_id ~sibling_order ~source =
  match
    ( validate_identity "mutation ID" mutation_id
    , validate_identity "block ID" block_id
    , validate_sibling_order sibling_order
    , Journal_validation.validate_source source )
  with
  | Ok (), Ok (), Ok (), Ok () -> Ok ()
  | (Error _ as result), _, _, _
  | _, (Error _ as result), _, _
  | _, _, (Error _ as result), _ -> result
  | _, _, _, Error message -> error message
;;

let canonical_title day =
  Printf.sprintf "%04d-%02d-%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
;;

let new_uuid () =
  match Datascript.squuid () with
  | Uuid uuid -> uuid
  | _ -> assert false
;;

let page_reference db day =
  match Datascript.entid db Journal_schema.Attr.page_day (Int day) with
  | Some entity_id -> Entity_id entity_id, []
  | None ->
    let page_id = new_uuid () in
    let reference = Temp_id ("journal-page:" ^ page_id) in
    ( reference
    , [ Add (reference, Journal_schema.Attr.page_id, Uuid page_id)
      ; Add (reference, Journal_schema.Attr.page_day, Int day)
      ; Add (reference, Journal_schema.Attr.page_title, String (canonical_title day))
      ] )
;;

let creation_transaction reference creation_time =
  [ Add
      ( reference
      , Journal_schema.Attr.block_created_instant_unix_ms
      , Int (Int64.to_int (Journal_time.instant_unix_ms creation_time)) )
  ; Add
      ( reference
      , Journal_schema.Attr.block_created_local_day
      , Int (Journal_time.local_day creation_time) )
  ; Add
      ( reference
      , Journal_schema.Attr.block_created_local_minute
      , Int (Journal_time.local_minute_of_day creation_time) )
  ; Add
      ( reference
      , Journal_schema.Attr.block_created_time_zone_id
      , String (Journal_time.time_zone_id creation_time) )
  ; Add
      ( reference
      , Journal_schema.Attr.block_created_utc_offset_seconds
      , Int (Journal_time.utc_offset_seconds creation_time) )
  ]
;;

let block_transaction
      reference
      ~page_reference
      ~parent_reference
      ~block_id
      ~sibling_order
      ~source
      ~task_state
      ~creation_time
      ~mutation_id
  =
  [ Add (reference, Journal_schema.Attr.block_id, Uuid block_id)
  ; Add (reference, Journal_schema.Attr.block_page, Ref_to page_reference)
  ; Add (reference, Journal_schema.Attr.block_parent, Ref_to parent_reference)
  ; Add (reference, Journal_schema.Attr.block_order, String sibling_order)
  ; Add (reference, Journal_schema.Attr.block_source, String source)
  ; Add
      ( reference
      , Journal_schema.Attr.block_task_state
      , Keyword (keyword_of_task_state task_state) )
  ]
  @ creation_transaction reference creation_time
  @ [ Add (reference, Journal_schema.Attr.block_revision, Int 1)
    ; Add (reference, Journal_schema.Attr.block_last_mutation_id, Uuid mutation_id)
    ]
;;

let prepare_capture db (command : capture) =
  match
    validate_new_block
      ~mutation_id:command.mutation_id
      ~block_id:command.block_id
      ~sibling_order:command.sibling_order
      ~source:command.source
  with
  | Error _ as result -> result
  | Ok () ->
    (match find_block db ~id:command.block_id with
     | Error _ as result -> result
     | Ok (Some block)
       when String.equal (Journal_model.last_mutation_id block) command.mutation_id ->
       Ok (Already_applied block)
     | Ok (Some _) -> error "capture block ID collides with an existing block"
     | Ok None ->
       let day = Journal_time.local_day command.creation_time in
       let page_reference, page_transaction = page_reference db day in
       let block_reference = Temp_id ("journal-block:" ^ command.block_id) in
       Ok
         (Apply
            (page_transaction
             @ block_transaction
                 block_reference
                 ~page_reference
                 ~parent_reference:page_reference
                 ~block_id:command.block_id
                 ~sibling_order:command.sibling_order
                 ~source:command.source
                 ~task_state:command.task_state
                 ~creation_time:command.creation_time
                 ~mutation_id:command.mutation_id)))
;;

let prepare_create_child db (command : create_child) =
  match
    ( validate_new_block
        ~mutation_id:command.mutation_id
        ~block_id:command.block_id
        ~sibling_order:command.sibling_order
        ~source:command.source
    , validate_identity "parent block ID" command.parent_block_id )
  with
  | (Error _ as result), _ | _, (Error _ as result) -> result
  | Ok (), Ok () ->
    if command.expected_parent_revision < 1
    then error "expected parent revision must be positive"
    else (
      match find_block db ~id:command.block_id with
      | Error _ as result -> result
      | Ok (Some child)
        when String.equal (Journal_model.last_mutation_id child) command.mutation_id ->
        Ok (Child_already_applied child)
      | Ok (Some _) -> error "child block ID collides with an existing block"
      | Ok None ->
        (match find_block db ~id:command.parent_block_id with
         | Error _ as result -> result
         | Ok None -> error "parent block does not exist"
         | Ok (Some parent)
           when Journal_model.revision parent <> command.expected_parent_revision ->
           error "parent block revision conflict"
         | Ok (Some parent) ->
           let parent_reference =
             Lookup_ref (Journal_schema.Attr.block_id, Uuid command.parent_block_id)
           in
           let page_reference =
             Lookup_ref (Journal_schema.Attr.page_id, Uuid (Journal_model.page_id parent))
           in
           let child_reference = Temp_id ("journal-child:" ^ command.block_id) in
           Ok
             (Create_child
                (CompareAndSet
                   ( parent_reference
                   , Journal_schema.Attr.block_revision
                   , Some (Int command.expected_parent_revision)
                   , Int (command.expected_parent_revision + 1) )
                 :: Add
                      ( parent_reference
                      , Journal_schema.Attr.block_last_mutation_id
                      , Uuid command.mutation_id )
                 :: block_transaction
                      child_reference
                      ~page_reference
                      ~parent_reference
                      ~block_id:command.block_id
                      ~sibling_order:command.sibling_order
                      ~source:command.source
                      ~task_state:command.task_state
                      ~creation_time:command.creation_time
                      ~mutation_id:command.mutation_id))))
;;

let prepare_block_update db ~mutation_id ~block_id ~expected_revision transaction =
  match
    ( validate_identity "update mutation ID" mutation_id
    , validate_identity "block ID" block_id )
  with
  | (Error _ as result), _ | _, (Error _ as result) -> result
  | Ok (), Ok () ->
    if expected_revision < 1
    then error "expected block revision must be positive"
    else (
      match find_block db ~id:block_id with
      | Error _ as result -> result
      | Ok None -> error "updated block does not exist"
      | Ok (Some block)
        when String.equal (Journal_model.last_mutation_id block) mutation_id ->
        Ok (Update_already_applied block)
      | Ok (Some block) when Journal_model.revision block <> expected_revision ->
        Ok (Update_conflict block)
      | Ok (Some _) ->
        let reference = Lookup_ref (Journal_schema.Attr.block_id, Uuid block_id) in
        Ok
          (Update_block
             (CompareAndSet
                ( reference
                , Journal_schema.Attr.block_revision
                , Some (Int expected_revision)
                , Int (expected_revision + 1) )
              :: Add
                   ( reference
                   , Journal_schema.Attr.block_last_mutation_id
                   , Uuid mutation_id )
              :: transaction reference)))
;;

let prepare_update_source db (command : update_source) =
  match Journal_validation.validate_source command.source with
  | Error message -> error message
  | Ok () ->
    prepare_block_update
      db
      ~mutation_id:command.mutation_id
      ~block_id:command.block_id
      ~expected_revision:command.expected_revision
      (fun reference ->
         [ Add (reference, Journal_schema.Attr.block_source, String command.source) ])
;;

let prepare_set_task_state db (command : set_task_state) =
  match command.task_state with
  | Journal_model.Not_a_task -> error "task transition target must be Todo or Done"
  | Todo | Done ->
    (match find_block db ~id:command.block_id with
     | Ok (Some block) when Journal_model.task_state block = Journal_model.Not_a_task ->
       error "non-task block cannot use a task-state transition"
     | Error _ as result -> result
     | Ok None | Ok (Some _) ->
       prepare_block_update
         db
         ~mutation_id:command.mutation_id
         ~block_id:command.block_id
         ~expected_revision:command.expected_revision
         (fun reference ->
            [ Add
                ( reference
                , Journal_schema.Attr.block_task_state
                , Keyword (keyword_of_task_state command.task_state) )
            ]))
;;

let child_entities db entity_id =
  let for_value value =
    Datascript.datoms db Avet ~a:Journal_schema.Attr.block_parent ~v:value ()
    |> Seq.map (fun datom -> datom.e)
    |> List.of_seq
  in
  match for_value (Ref entity_id) with
  | _ :: _ as children -> children
  | [] -> for_value (Int entity_id)
;;

let block_for_entity db entity_id =
  let datoms = Datascript.datoms db Eavt ~e:entity_id () |> List.of_seq in
  match one_value datoms Journal_schema.Attr.block_id with
  | Error _ as result -> result
  | Ok (Uuid block_id) ->
    (match find_block db ~id:block_id with
     | Ok (Some block) -> Ok block
     | Ok None -> error "subtree entity cannot be projected as a Block"
     | Error _ as result -> result)
  | Ok _ -> error "subtree entity has an invalid Block identity"
;;

let collect_subtree db ~root_entity ~root_page_id =
  let rec loop pending visited collected =
    match pending with
    | [] -> Ok collected
    | (entity_id, depth) :: tail ->
      if List.mem entity_id visited
      then error "subtree structure contains a cycle or repeated entity"
      else (
        match block_for_entity db entity_id with
        | Error _ as result -> result
        | Ok block when not (String.equal (Journal_model.page_id block) root_page_id) ->
          error "subtree descendant belongs to a different journal page"
        | Ok _ ->
          let children =
            child_entities db entity_id
            |> List.map (fun child_entity -> child_entity, depth + 1)
          in
          loop
            (List.rev_append children tail)
            (entity_id :: visited)
            ((depth, entity_id) :: collected))
  in
  loop [ root_entity, 0 ] [] []
;;

let prepare_delete_subtree db (command : delete_subtree) =
  match
    ( validate_identity "delete mutation ID" command.mutation_id
    , validate_identity "block ID" command.block_id )
  with
  | (Error _ as result), _ | _, (Error _ as result) -> result
  | Ok (), Ok () ->
    if command.expected_revision < 1
    then error "expected block revision must be positive"
    else (
      match find_block db ~id:command.block_id with
      | Error _ as result -> result
      | Ok None -> Ok Delete_already_applied
      | Ok (Some root) when Journal_model.revision root <> command.expected_revision ->
        Ok (Delete_conflict root)
      | Ok (Some root) ->
        (match
           Datascript.entid db Journal_schema.Attr.block_id (Uuid command.block_id)
         with
         | None -> error "delete root disappeared during preflight"
         | Some root_entity ->
           (match
              collect_subtree db ~root_entity ~root_page_id:(Journal_model.page_id root)
            with
            | Error _ as result -> result
            | Ok collected ->
              let deepest_first =
                List.sort
                  (fun (left_depth, _) (right_depth, _) ->
                     Int.compare right_depth left_depth)
                  collected
              in
              let retractions =
                List.map
                  (fun (_, entity_id) -> RetractEntity (Entity_id entity_id))
                  deepest_first
              in
              let parent_block_id = Journal_model.parent_id root in
              let parent_update =
                match parent_block_id with
                | None -> Ok []
                | Some parent_id ->
                  (match find_block db ~id:parent_id with
                   | Error _ as result -> result
                   | Ok None -> error "delete root Block parent does not exist"
                   | Ok (Some parent) ->
                     let reference =
                       Lookup_ref (Journal_schema.Attr.block_id, Uuid parent_id)
                     in
                     let revision = Journal_model.revision parent in
                     Ok
                       [ CompareAndSet
                           ( reference
                           , Journal_schema.Attr.block_revision
                           , Some (Int revision)
                           , Int (revision + 1) )
                       ; Add
                           ( reference
                           , Journal_schema.Attr.block_last_mutation_id
                           , Uuid command.mutation_id )
                       ])
              in
              (match parent_update with
               | Error _ as result -> result
               | Ok parent_update ->
                 Ok
                   (Delete_subtree
                      { transaction = parent_update @ retractions
                      ; deleted_count = List.length collected
                      ; parent_block_id
                      })))))
;;

let tuple_parent = function
  | Tuple (Some (Ref parent) :: _) -> Some parent
  | Tuple (Some (Int parent) :: _) -> Some parent
  | _ -> None
;;

let tuple_order_and_id = function
  | Tuple [ _; Some (String sibling_order); Some (Uuid id) ] -> Some (sibling_order, id)
  | _ -> None
;;

let is_after_cursor cursor sibling_order id =
  match cursor with
  | None -> true
  | Some cursor ->
    let comparison = String.compare sibling_order cursor.after_sibling_order in
    comparison > 0 || (comparison = 0 && String.compare id cursor.after_block_id > 0)
;;

let validate_block_cursor = function
  | None -> Ok ()
  | Some cursor ->
    (match validate_sibling_order cursor.after_sibling_order with
     | Error _ as result -> result
     | Ok () -> validate_identity "block cursor ID" cursor.after_block_id)
;;

let ordered_blocks_for_parent db ~parent_entity ~after ~limit =
  let materialize parent_value =
    let lower =
      match after with
      | None -> Tuple [ Some parent_value; None; None ]
      | Some cursor ->
        Tuple
          [ Some parent_value
          ; Some (String cursor.after_sibling_order)
          ; Some (Uuid cursor.after_block_id)
          ]
    in
    let rec loop remaining sequence blocks =
      if remaining = 0
      then Ok (List.rev blocks)
      else (
        match sequence () with
        | Seq.Nil -> Ok (List.rev blocks)
        | Seq.Cons (datom, tail) ->
          if tuple_parent datom.v <> Some parent_entity
          then Ok (List.rev blocks)
          else (
            match tuple_order_and_id datom.v with
            | Some (sibling_order, id) when not (is_after_cursor after sibling_order id)
              -> loop remaining tail blocks
            | Some (_, id) ->
              (match find_block db ~id with
               | Error _ as result -> result
               | Ok None -> error "derived block order points at a missing block"
               | Ok (Some block) -> loop (remaining - 1) tail (block :: blocks))
            | None -> error "derived block order has an invalid tuple value"))
    in
    loop
      limit
      (Datascript.seek_datoms
         db
         Avet
         ~a:Journal_schema.Attr.block_parent_order_block
         ~v:lower
         ())
      []
  in
  match materialize (Ref parent_entity) with
  | Error _ as result -> result
  | Ok (_ :: _ as blocks) -> Ok blocks
  | Ok [] -> materialize (Int parent_entity)
;;

let block_page_for_parent db ~parent_entity ~after ~limit =
  match ordered_blocks_for_parent db ~parent_entity ~after ~limit:(limit + 1) with
  | Error _ as result -> result
  | Ok blocks ->
    let has_more = List.length blocks > limit in
    let blocks =
      if has_more then List.filteri (fun index _ -> index < limit) blocks else blocks
    in
    let continuation =
      if has_more
      then
        List.nth_opt blocks (List.length blocks - 1)
        |> Option.map (fun block ->
          { after_sibling_order = Journal_model.sibling_order block
          ; after_block_id = Journal_model.id block
          })
      else None
    in
    Ok { blocks; continuation }
;;

let load_children db ~parent_id ~after ~limit =
  if limit < 1 || limit > 64
  then error "child block limit must be between 1 and 64"
  else (
    match validate_identity "parent block ID" parent_id, validate_block_cursor after with
    | (Error _ as result), _ | _, (Error _ as result) -> result
    | Ok (), Ok () ->
      (match Datascript.entid db Journal_schema.Attr.block_id (Uuid parent_id) with
       | None -> error "parent block does not exist"
       | Some parent_entity -> block_page_for_parent db ~parent_entity ~after ~limit))
;;

let load_day_blocks db ~day ~after ~limit =
  if not (Journal_validation.is_journal_day day)
  then error "Journal day must be a valid YYYYMMDD date"
  else if limit < 1 || limit > 64
  then error "day block limit must be between 1 and 64"
  else (
    match validate_block_cursor after with
    | Error _ as result -> result
    | Ok () ->
      (match Datascript.entid db Journal_schema.Attr.page_day (Int day) with
       | None -> Ok { blocks = []; continuation = None }
       | Some page_entity ->
         block_page_for_parent db ~parent_entity:page_entity ~after ~limit))
;;

let load_detail db ~block_id ~after ~limit =
  match find_block db ~id:block_id with
  | Error _ as result -> result
  | Ok None -> error "detail root block does not exist"
  | Ok (Some root) ->
    (match load_children db ~parent_id:block_id ~after ~limit with
     | Error _ as result -> result
     | Ok children -> Ok { root; children })
;;

let top_level_blocks db ~day ~limit =
  match load_day_blocks db ~day ~after:None ~limit with
  | Error _ as result -> result
  | Ok page -> Ok page.blocks
;;

let recent_pages_unchecked db ~before_day ~limit =
  let start_day =
    match before_day with
    | None -> 99_991_231
    | Some day -> day - 1
  in
  let rec materialize remaining sequence pages =
    if remaining = 0
    then Ok (List.rev pages, true)
    else (
      match sequence () with
      | Seq.Nil -> Ok (List.rev pages, false)
      | Seq.Cons (datom, tail) ->
        if not (String.equal datom.a Journal_schema.Attr.page_day)
        then Ok (List.rev pages, false)
        else (
          match page_for_entity db datom.e with
          | Error _ as result -> result
          | Ok page -> materialize (remaining - 1) tail (page :: pages)))
  in
  materialize
    (limit + 1)
    (Datascript.rseek_datoms
       db
       Avet
       ~a:Journal_schema.Attr.page_day
       ~v:(Int start_day)
       ())
    []
  |> Result.map (fun (pages, reached_limit) ->
    if reached_limit
    then List.filteri (fun index _ -> index < limit) pages, true
    else pages, false)
;;

let recent_pages db ~before_day ~limit =
  if limit < 1 || limit > 31
  then error "recent page limit must be between 1 and 31"
  else (
    match before_day with
    | Some day when not (Journal_validation.is_journal_day day) ->
      error "before-day cursor is invalid"
    | None | Some _ -> recent_pages_unchecked db ~before_day ~limit)
;;

let page_blocks_with_more db (page : page) limit =
  match Datascript.entid db Journal_schema.Attr.page_day (Int page.day) with
  | None -> error "feed page disappeared"
  | Some page_entity ->
    (match
       ordered_blocks_for_parent
         db
         ~parent_entity:page_entity
         ~after:None
         ~limit:(limit + 1)
     with
     | Error _ as result -> result
     | Ok blocks when List.length blocks > limit ->
       Ok (List.filteri (fun index _ -> index < limit) blocks, true)
     | Ok blocks -> Ok (blocks, false))
;;

let load_feed db ~before_day ~day_limit ~blocks_per_day ~slot_limit =
  if day_limit < 1 || day_limit > 31
  then error "feed day limit must be between 1 and 31"
  else if blocks_per_day < 1 || blocks_per_day > 64
  then error "feed block limit must be between 1 and 64"
  else if slot_limit < 3 || slot_limit > 128
  then error "feed slot limit must be between 3 and 128"
  else (
    match recent_pages db ~before_day ~limit:day_limit with
    | Error _ as result -> result
    | Ok (pages, source_has_more) ->
      let rec build pages days slot_count =
        match pages with
        | [] -> Ok { days = List.rev days; slot_count; has_more_days = source_has_more }
        | page :: remaining ->
          (match page_blocks_with_more db page blocks_per_day with
           | Error _ as result -> result
           | Ok (blocks, has_more_blocks) ->
             let required = 1 + List.length blocks + if has_more_blocks then 1 else 0 in
             if slot_count + required > slot_limit
             then Ok { days = List.rev days; slot_count; has_more_days = true }
             else
               build
                 remaining
                 ({ page; blocks; has_more_blocks } :: days)
                 (slot_count + required))
      in
      build pages [] 0)
;;

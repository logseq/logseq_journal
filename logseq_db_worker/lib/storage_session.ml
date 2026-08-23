type lifecycle =
  | Open
  | Fatal_state of string
  | Closed_state

type physical_indexes =
  { eavt : Datascript.datom Persistent_sorted_set.t
  ; aevt : Datascript.datom Persistent_sorted_set.t
  ; avet : Datascript.datom Persistent_sorted_set.t
  ; duplicates : Datascript.datom list
  ; settings : Persistent_sorted_set.settings
  ; next_address : int ref
  ; metadata : Logseq_sqlite_codec.root_index_metadata
  }

type t =
  { mutable db : Datascript.db
  ; callbacks : Logseq_sqlite_storage.callbacks
  ; mutable tail : Datascript.datom list list
  ; mutable physical : physical_indexes
  ; mutable unreachable_address_count : int option
  ; mutable garbage_collection_size_baseline : int64
  ; mutable lifecycle : lifecycle
  }

type staged =
  { db_after : Datascript.db
  ; tx_data : Datascript.datom list
  ; batch : Logseq_sqlite_storage.batch
  ; tail_after : Datascript.datom list list
  ; physical_after : physical_indexes option
  ; mutable consumed : bool
  }

type error =
  | Closed
  | Fatal of string
  | Stage_failed of string
  | Persistence_failed of string
  | Already_consumed

let garbage_collection_unreachable_address_threshold = 256
let garbage_collection_file_growth_threshold_bytes = Int64.of_int (16 * 1_024 * 1_024)

let compare_attr left right =
  compare (Datascript.Util.split_keyword left) (Datascript.Util.split_keyword right)
;;

let compare_datom index left right =
  let first_nonzero = Datascript.Util.first_nonzero in
  match index with
  | Datascript.Eavt ->
    first_nonzero
      [ compare left.Datascript.e right.Datascript.e
      ; compare_attr left.Datascript.a right.Datascript.a
      ; Datascript.Util.compare_value left.Datascript.v right.Datascript.v
      ; compare left.Datascript.tx right.Datascript.tx
      ]
  | Aevt ->
    first_nonzero
      [ compare_attr left.Datascript.a right.Datascript.a
      ; compare left.Datascript.e right.Datascript.e
      ; Datascript.Util.compare_value left.Datascript.v right.Datascript.v
      ; compare left.Datascript.tx right.Datascript.tx
      ]
  | Avet ->
    first_nonzero
      [ compare_attr left.Datascript.a right.Datascript.a
      ; Datascript.Util.compare_value left.Datascript.v right.Datascript.v
      ; compare left.Datascript.e right.Datascript.e
      ; compare left.Datascript.tx right.Datascript.tx
      ]
;;

let split_primary_and_duplicates datoms =
  let sorted = List.sort (compare_datom Datascript.Eavt) datoms in
  let rec loop previous primary duplicates = function
    | [] -> List.rev primary, List.rev duplicates
    | datom :: rest ->
      (match previous with
       | Some previous when compare_datom Datascript.Eavt previous datom = 0 ->
         loop (Some datom) primary (datom :: duplicates) rest
       | None | Some _ -> loop (Some datom) (datom :: primary) duplicates rest)
  in
  loop None [] [] sorted
;;

let physical_indexes ~attached callbacks db =
  let existing_root =
    match
      callbacks.Logseq_sqlite_storage.storage.storage_restore
        Datascript.Storage.root_address
    with
    | Some (Datascript.Storage_root root) when attached -> Some root
    | Some _ | None -> None
  in
  let settings, next_address =
    match existing_root with
    | Some root ->
      ( { Persistent_sorted_set.branching_factor = root.storage_branching_factor
        ; ref_type = root.storage_ref_type
        }
      , ref root.storage_max_addr )
    | None -> Persistent_sorted_set.default_settings, ref 1_000_000
  in
  let node_storage : Datascript.datom Persistent_sorted_set.storage =
    { store_node =
        (fun node ->
          incr next_address;
          let address = string_of_int !next_address in
          callbacks.storage.storage_store [ address, Datascript.Storage_node node ];
          address)
    ; restore_node =
        (fun address ->
          match callbacks.storage.storage_restore address with
          | Some (Datascript.Storage_node node) -> Some node
          | Some _ -> invalid_arg ("storage address is not an index node: " ^ address)
          | None -> None)
    ; accessed = (fun _ -> ())
    }
  in
  let restore index address =
    match
      Persistent_sorted_set.restore
        ~cmp:(compare_datom index)
        ~settings
        node_storage
        address
    with
    | Some set -> set
    | None -> invalid_arg ("unable to restore physical index " ^ address)
  in
  match existing_root with
  | Some root ->
    let metadata =
      match callbacks.initial_root_metadata with
      | Some metadata -> metadata
      | None ->
        let count address index = Persistent_sorted_set.count (restore index address) in
        { Logseq_sqlite_codec.eavt =
            { count = count root.storage_eavt Datascript.Eavt; shift = 0 }
        ; aevt = { count = count root.storage_aevt Aevt; shift = 0 }
        ; avet = { count = count root.storage_avet Avet; shift = 0 }
        }
    in
    { eavt = restore Datascript.Eavt root.storage_eavt
    ; aevt = restore Aevt root.storage_aevt
    ; avet = restore Avet root.storage_avet
    ; duplicates = root.storage_duplicate_datoms
    ; settings
    ; next_address
    ; metadata
    }
  | None ->
    let snapshot = Datascript.serializable db in
    let primary, duplicates = split_primary_and_duplicates snapshot.serializable_datoms in
    let make index datoms =
      let values = Array.of_list (List.sort (compare_datom index) datoms) in
      Persistent_sorted_set.of_sorted_array_by
        ~settings
        ~storage:node_storage
        ~cmp:(compare_datom index)
        values
    in
    let avet =
      List.filter
        (fun datom ->
           Datascript.Schema.schema_attr_is_avet_accessible
             snapshot.serializable_schema
             datom.Datascript.a)
        primary
    in
    { eavt = make Datascript.Eavt primary
    ; aevt = make Aevt primary
    ; avet = make Avet avet
    ; duplicates
    ; settings
    ; next_address
    ; metadata =
        { Logseq_sqlite_codec.eavt = { count = List.length primary; shift = 0 }
        ; aevt = { count = List.length primary; shift = 0 }
        ; avet = { count = List.length avet; shift = 0 }
        }
    }
;;

let create ~db ~tail ~callbacks =
  let attached = Option.is_some (Datascript.storage db) in
  let physical = physical_indexes ~attached callbacks db in
  let unreachable_address_count =
    if attached then None else Some 0
  in
  { db
  ; callbacks
  ; tail
  ; physical
  ; unreachable_address_count
  ; garbage_collection_size_baseline = callbacks.database_size_bytes ()
  ; lifecycle = Open
  }
;;

let current_db t = t.db
let current_tail t = t.tail
let staged_db_after staged = staged.db_after
let staged_tx_data staged = staged.tx_data
let datom_with_tx datom tx = { datom with Datascript.tx }

let physical_fact_matches physical datom =
  Persistent_sorted_set.slice
    ~from_:(datom_with_tx datom min_int)
    ~to_:(datom_with_tx datom max_int)
    physical.eavt
;;

let update_physical schema physical datom =
  let remove datom (eavt, aevt, avet) =
    ( Persistent_sorted_set.remove datom eavt
    , Persistent_sorted_set.remove datom aevt
    , if Datascript.Schema.schema_attr_is_avet_accessible schema datom.Datascript.a
      then Persistent_sorted_set.remove datom avet
      else avet )
  in
  let add datom (eavt, aevt, avet) =
    ( Persistent_sorted_set.add datom eavt
    , Persistent_sorted_set.add datom aevt
    , if Datascript.Schema.schema_attr_is_avet_accessible schema datom.Datascript.a
      then Persistent_sorted_set.add datom avet
      else avet )
  in
  let sets = physical.eavt, physical.aevt, physical.avet in
  let eavt, aevt, avet, delta, avet_delta =
    if datom.Datascript.added
    then
      if Persistent_sorted_set.mem datom physical.eavt
      then (
        let eavt, aevt, avet = sets in
        eavt, aevt, avet, 0, 0)
      else (
        let eavt, aevt, avet = add datom sets in
        ( eavt
        , aevt
        , avet
        , 1
        , if Datascript.Schema.schema_attr_is_avet_accessible schema datom.Datascript.a
          then 1
          else 0 ))
    else (
      let matches = physical_fact_matches physical datom in
      let eavt, aevt, avet =
        List.fold_left (fun sets old -> remove old sets) sets matches
      in
      ( eavt
      , aevt
      , avet
      , -List.length matches
      , if Datascript.Schema.schema_attr_is_avet_accessible schema datom.Datascript.a
        then -List.length matches
        else 0 ))
  in
  let add_count (metadata : Logseq_sqlite_codec.index_metadata) delta =
    { metadata with Logseq_sqlite_codec.count = metadata.count + delta }
  in
  { physical with
    eavt
  ; aevt
  ; avet
  ; metadata =
      { Logseq_sqlite_codec.eavt = add_count physical.metadata.eavt delta
      ; aevt = add_count physical.metadata.aevt delta
      ; avet = add_count physical.metadata.avet avet_delta
      }
  }
;;

let compact_physical callbacks physical db tail =
  let snapshot = Datascript.serializable db in
  let physical =
    List.fold_left
      (fun physical group ->
         List.fold_left (update_physical snapshot.serializable_schema) physical group)
      physical
      tail
  in
  let eavt_address, eavt = Persistent_sorted_set.store physical.eavt in
  let aevt_address, aevt = Persistent_sorted_set.store physical.aevt in
  let avet_address, avet = Persistent_sorted_set.store physical.avet in
  let index_shift address =
    let rec descend shift address =
      match callbacks.Logseq_sqlite_storage.storage.storage_restore address with
      | Some (Datascript.Storage_node (Persistent_sorted_set.Leaf _)) -> shift
      | Some (Storage_node (Branch (_, child :: _))) -> descend (shift + 1) child
      | Some (Storage_node (Branch (_, []))) ->
        invalid_arg ("physical index has an empty branch at " ^ address)
      | Some (Storage_root _ | Storage_tail _) ->
        invalid_arg ("physical index points at non-node address " ^ address)
      | None -> invalid_arg ("physical index points at missing address " ^ address)
    in
    descend 0 address
  in
  let metadata =
    { Logseq_sqlite_codec.eavt =
        { physical.metadata.eavt with shift = index_shift eavt_address }
    ; aevt = { physical.metadata.aevt with shift = index_shift aevt_address }
    ; avet = { physical.metadata.avet with shift = index_shift avet_address }
    }
  in
  let root =
    Datascript.
      { storage_schema = snapshot.serializable_schema
      ; storage_max_eid = snapshot.serializable_max_eid
      ; storage_max_tx = snapshot.serializable_max_tx
      ; storage_eavt = eavt_address
      ; storage_aevt = aevt_address
      ; storage_avet = avet_address
      ; storage_duplicate_datoms = physical.duplicates
      ; storage_max_addr = !(physical.next_address)
      ; storage_branching_factor = physical.settings.branching_factor
      ; storage_ref_type = physical.settings.ref_type
      }
  in
  ( { physical with eavt; aevt; avet; metadata }
  , [ Datascript.Storage.root_address, Datascript.Storage_root root
    ; Datascript.Storage.tail_address, Datascript.Storage_tail []
    ] )
;;

let stage_transact_batch ?tx_meta t transaction_batches =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Fatal_state message -> Error (Fatal message)
  | Open ->
    (try
       let tx_meta =
         ("skip-store?", Datascript.Bool true) :: Option.value tx_meta ~default:[]
       in
       let db_after, added_tail, tx_data =
         List.fold_left
           (fun (db, tail, all_tx_data) tx_ops ->
              let report = Datascript.with_tx ~tx_meta db tx_ops in
              ( report.db_after
              , (if report.tx_data = [] then tail else tail @ [ report.tx_data ])
              , all_tx_data @ report.tx_data ))
           (t.db, [], [])
           transaction_batches
       in
       let tail_after = t.tail @ added_tail in
       let compact =
         Datascript.Storage.tail_datom_count tail_after
         > Datascript.Storage.tail_compaction_threshold
       in
       match t.callbacks.begin_staging () with
       | Error message -> Error (Stage_failed message)
       | Ok () ->
         let physical_after, entries =
           if compact
           then (
             let physical, entries =
               compact_physical t.callbacks t.physical db_after tail_after
             in
             Some physical, entries)
           else
             None, [ Datascript.Storage.tail_address, Datascript.Storage_tail tail_after ]
         in
         let metadata = Option.map (fun physical -> physical.metadata) physical_after in
         (match t.callbacks.finish_staging metadata entries with
          | Error message ->
            t.callbacks.abort_staging ();
            Error (Stage_failed message)
          | Ok batch ->
            Ok
              { db_after
              ; tx_data
              ; batch
              ; tail_after = (if compact then [] else tail_after)
              ; physical_after
              ; consumed = false
              })
     with
     | exn ->
       t.callbacks.abort_staging ();
       Error (Stage_failed (Printexc.to_string exn)))
;;

let stage_transact ?tx_meta t tx_ops =
  stage_transact_batch ?tx_meta t [ tx_ops ]
;;

let storage_error_message = function
  | Logseq_sqlite_storage.Pragma_mismatch message
  | Corrupt_storage message
  | Begin_failed message
  | Commit_failed message
  | Checkpoint_failed message
  | Close_failed message -> message
  | Write_failed { address; message } -> address ^ ": " ^ message
;;

let terminalize t message =
  t.lifecycle <- Fatal_state message;
  Error (Persistence_failed message)
;;

let commit_staged_internal t staged sync_metadata =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Fatal_state message -> Error (Fatal message)
  | Open ->
    if staged.consumed
    then Error Already_consumed
    else (
      staged.consumed <- true;
      let batch = { staged.batch with Logseq_sqlite_storage.sync_metadata } in
      match Logseq_sqlite_storage.commit_batch t.callbacks batch with
      | Error error -> terminalize t (storage_error_message error)
      | Ok () ->
        t.db <- staged.db_after;
        t.tail <- staged.tail_after;
        Option.iter (fun physical -> t.physical <- physical) staged.physical_after;
        (match staged.physical_after with
         | None -> Ok ()
         | Some _ ->
           let new_index_nodes =
             List.fold_left
               (fun count (write : Logseq_sqlite_storage.write) ->
                  if
                    String.equal write.address Datascript.Storage.root_address
                    || String.equal write.address Datascript.Storage.tail_address
                  then count
                  else count + 1)
               0
               staged.batch.writes
           in
           t.unreachable_address_count
           <- Option.map
                (fun count -> count + new_index_nodes)
                t.unreachable_address_count;
           Ok ()))
;;

let commit_staged t staged = commit_staged_internal t staged None

let commit_staged_with_sync_metadata t staged metadata =
  commit_staged_internal t staged (Some metadata)
;;

let persist_sync_metadata t metadata =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Fatal_state message -> Error (Fatal message)
  | Open ->
    (match Logseq_sqlite_storage.commit_sync_metadata t.callbacks metadata with
     | Ok () -> Ok ()
     | Error error -> terminalize t (storage_error_message error))
;;

let garbage_collection_needed t =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Fatal_state message -> Error (Fatal message)
  | Open ->
    let unreachable_address_count =
      match t.unreachable_address_count with
      | Some count -> count
      | None ->
        let count = t.callbacks.unreachable_address_count () in
        t.unreachable_address_count <- Some count;
        count
    in
    let growth =
      Int64.sub (t.callbacks.database_size_bytes ()) t.garbage_collection_size_baseline
    in
    Ok
      (unreachable_address_count >= garbage_collection_unreachable_address_threshold
       || Int64.compare growth garbage_collection_file_growth_threshold_bytes >= 0)
;;

let collect_garbage t =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Fatal_state message -> Error (Fatal message)
  | Open ->
    (match Logseq_sqlite_storage.collect_garbage t.callbacks with
     | Ok () ->
       t.unreachable_address_count <- Some 0;
       t.garbage_collection_size_baseline <- t.callbacks.database_size_bytes ();
       Ok ()
     | Error error -> terminalize t (storage_error_message error))
;;

let close t =
  match t.lifecycle with
  | Closed_state -> Error Closed
  | Open | Fatal_state _ ->
    let checkpoint = Logseq_sqlite_storage.checkpoint t.callbacks in
    let close = Logseq_sqlite_storage.close t.callbacks in
    t.lifecycle <- Closed_state;
    (match checkpoint, close with
     | Ok (), Ok () -> Ok ()
     | Error checkpoint, Ok () ->
       Error (Persistence_failed (storage_error_message checkpoint))
     | Ok (), Error close -> Error (Persistence_failed (storage_error_message close))
     | Error checkpoint, Error close ->
       Error
         (Persistence_failed
            (storage_error_message checkpoint ^ "; " ^ storage_error_message close)))
;;

let is_fatal t =
  match t.lifecycle with
  | Fatal_state _ -> true
  | Open | Closed_state -> false
;;

open Datascript

module Attr = struct
  let store_id = "journal.store/id"
  let store_schema_version = "journal.store/schema-version"
  let page_id = "journal.page/id"
  let page_day = "journal.page/day"
  let page_title = "journal.page/title"
  let block_id = "journal.block/id"
  let block_page = "journal.block/page"
  let block_parent = "journal.block/parent"
  let block_order = "journal.block/order"
  let block_parent_order = "journal.block/parent-order"
  let block_parent_order_block = "journal.block/parent-order-block"
  let block_source = "journal.block/source"
  let block_task_state = "journal.block/task-state"
  let block_created_instant_unix_ms = "journal.block/created-instant-unix-ms"
  let block_created_local_day = "journal.block/created-local-day"
  let block_created_local_minute = "journal.block/created-local-minute"
  let block_created_time_zone_id = "journal.block/created-time-zone-id"
  let block_created_utc_offset_seconds = "journal.block/created-utc-offset-seconds"
  let block_revision = "journal.block/revision"
  let block_last_mutation_id = "journal.block/last-mutation-id"
end

module Error = struct
  type t = string

  let to_string error = error
end

let version = 1
let store_identity = "logseq-journal-timeline"

let attribute
      ?unique
      ?(indexed = false)
      ?(is_component = false)
      ?(no_history = false)
      ?value_type
      ?tuple_attrs
      ()
  =
  { cardinality = One
  ; unique
  ; indexed
  ; is_component
  ; no_history
  ; doc = None
  ; value_type
  ; tuple_attrs
  ; tuple_types = None
  }
;;

let unique_uuid = attribute ~unique:Identity ~indexed:true ~value_type:UuidType ()
let indexed_ref = attribute ~indexed:true ~value_type:RefType ()

let data_script =
  [ Attr.store_id, attribute ~unique:Identity ~indexed:true ~value_type:StringType ()
  ; Attr.store_schema_version, attribute ~indexed:true ~value_type:NumberType ()
  ; Attr.page_id, unique_uuid
  ; Attr.page_day, attribute ~unique:Value ~indexed:true ~value_type:NumberType ()
  ; Attr.page_title, attribute ~value_type:StringType ()
  ; Attr.block_id, unique_uuid
  ; Attr.block_page, indexed_ref
  ; Attr.block_parent, indexed_ref
  ; Attr.block_order, attribute ~indexed:true ~value_type:StringType ()
  ; ( Attr.block_parent_order
    , attribute
        ~indexed:true
        ~value_type:TupleType
        ~tuple_attrs:[ Attr.block_parent; Attr.block_order ]
        () )
  ; ( Attr.block_parent_order_block
    , attribute
        ~indexed:true
        ~value_type:TupleType
        ~tuple_attrs:[ Attr.block_parent; Attr.block_order; Attr.block_id ]
        () )
  ; Attr.block_source, attribute ~value_type:StringType ()
  ; Attr.block_task_state, attribute ~value_type:KeywordType ()
  ; Attr.block_created_instant_unix_ms, attribute ~value_type:NumberType ()
  ; Attr.block_created_local_day, attribute ~value_type:NumberType ()
  ; Attr.block_created_local_minute, attribute ~value_type:NumberType ()
  ; Attr.block_created_time_zone_id, attribute ~value_type:StringType ()
  ; Attr.block_created_utc_offset_seconds, attribute ~value_type:NumberType ()
  ; Attr.block_revision, attribute ~value_type:NumberType ()
  ; Attr.block_last_mutation_id, attribute ~value_type:UuidType ()
  ]
;;

let sorted schema =
  List.sort (fun (left, _) (right, _) -> String.compare left right) schema
;;

let validate_schema schema =
  match Datascript.Schema.validate_schema schema with
  | validated when sorted validated = sorted data_script -> Ok ()
  | _ -> Error "store schema does not exactly match the application schema"
  | exception Invalid_argument message -> Error ("invalid store schema: " ^ message)
;;

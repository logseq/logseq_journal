open Graph_types

type context =
  { mutation_id : Uuid.t
  ; expected_basis : int64
  }

type relative_position =
  | Before of block_uuid
  | After of block_uuid
  | First_child of block_uuid
  | Last_child of block_uuid

and insert_position =
  | Relative of relative_position
  | Replace_empty of block_uuid

and direction =
  | Up
  | Down

and indent_direction =
  | Indent
  | Direct_outdent

and block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : block_tree list
  }

and structural_mutation =
  | Save_block of
      { block : block_uuid
      ; title : string
      ; context : context
      }
  | Insert_blocks of
      { roots : block_tree list
      ; position : insert_position
      ; context : context
      }
  | Move_blocks of
      { roots : block_uuid list
      ; position : relative_position
      ; context : context
      }
  | Move_up_down of
      { roots : block_uuid list
      ; direction : direction
      ; context : context
      }
  | Indent_outdent of
      { roots : block_uuid list
      ; direction : indent_direction
      ; context : context
      }
  | Delete_blocks of
      { roots : block_uuid list
      ; context : context
      }

and create_page_kind =
  | Create_ordinary_page of { uuid : page_uuid }
  | Create_journal_page of
      { journal_day : int
      ; supplied_uuid : page_uuid option
      }
  | Create_class_page of { uuid : class_uuid }

and page_mutation =
  | Create_page of
      { title : string
      ; kind : create_page_kind
      ; context : context
      }
  | Rename_page of
      { page : page_uuid
      ; title : string
      ; context : context
      }
  | Delete_page of
      { page : page_uuid
      ; context : context
      }
  | Restore_recycled_page of
      { page : page_uuid
      ; context : context
      }
  | Permanently_delete_recycled_page of
      { page : page_uuid
      ; context : context
      }

and property_identity =
  | Existing_property of property_selector
  | New_property of
      { ident : qualified_ident
      ; title : string
      }

and batch_set_mode =
  | Append of property_value
  | Replace of property_value list

and closed_value_action =
  | Add_closed_value of
      { value_uuid : block_uuid
      ; value : property_value
      ; icon : string option
      }
  | Update_closed_value of
      { value_uuid : block_uuid
      ; value : property_value
      ; icon : string option
      }
  | Associate_closed_value of { value_uuid : block_uuid }
  | Delete_closed_value of { value_uuid : block_uuid }

and class_property_action =
  | Add_class_property of { default_value : property_value option }
  | Remove_class_property

and property_mutation =
  | Upsert_property of
      { property : property_identity
      ; schema : property_schema
      ; context : context
      }
  | Set_property of
      { block : block_uuid
      ; property : property_selector
      ; value : property_value
      ; context : context
      }
  | Remove_property of
      { block : block_uuid
      ; property : property_selector
      ; context : context
      }
  | Batch_set_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; mode : batch_set_mode
      ; context : context
      }
  | Batch_remove_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; context : context
      }
  | Manage_closed_values of
      { property : property_selector
      ; action : closed_value_action
      ; context : context
      }
  | Manage_class_property of
      { class_ : class_uuid
      ; property : property_selector
      ; action : class_property_action
      ; context : context
      }

and t =
  | Structural of structural_mutation
  | Page of page_mutation
  | Property of property_mutation

type status =
  | Applied
  | No_change
  | Already_applied

type success =
  { status : status
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : Uuid.t list
  ; changed_uuids_truncated : bool
  }

val context : t -> context
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val property_selector_to_yojson : property_selector -> Yojson.Safe.t
val property_selector_of_yojson : Yojson.Safe.t -> (property_selector, string) result
val property_schema_to_yojson : property_schema -> Yojson.Safe.t
val property_schema_of_yojson : Yojson.Safe.t -> (property_schema, string) result
val property_value_to_yojson : property_value -> Yojson.Safe.t
val property_value_of_yojson : Yojson.Safe.t -> (property_value, string) result

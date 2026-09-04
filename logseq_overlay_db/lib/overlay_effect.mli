module Graph = Logseq_db_types.Graph_types

type footprint =
  { block_uuids : Graph.block_uuid list
  ; page_uuids : Graph.page_uuid list
  ; structure_interests : Types.structure_interest list
  }

type delete_block_patch =
  { block_uuid : Graph.block_uuid
  ; title : string
  ; refs : Graph.block_uuid list
  ; updated_at_ms : int64
  }

type delete_page_patch =
  { page_uuid : Graph.page_uuid
  ; updated_at_ms : int64
  }

type delete_property_patch =
  { holder_uuid : Graph.block_uuid
  ; property_ident : string
  ; replacement_uuid : Graph.Uuid.t
  ; updated_at_ms : int64
  }

type delete_property_guard =
  { property_uuid : Graph.property_uuid
  ; property_ident : string
  ; replacement_uuid : Graph.Uuid.t
  }

type delete_artifacts =
  { frontier : Graph.block_uuid list
  ; block_patches : delete_block_patch list
  ; page_patches : delete_page_patch list
  ; property_guard : delete_property_guard option
  ; property_patches : delete_property_patch list
  }

type dependency_block_shadow =
  { shadow_block_uuid : Graph.block_uuid
  ; shadow_title : string
  ; shadow_parent : Graph.Uuid.t
  ; shadow_page : Graph.page_uuid
  ; shadow_order : string
  ; shadow_created_at_ms : int64
  ; shadow_updated_at_ms : int64
  ; shadow_task_status : Types.task_status option
  }

type dependency_page_shadow =
  { shadow_page_uuid : Graph.page_uuid
  ; shadow_name : string
  ; shadow_page_title : string
  ; shadow_page_kind : Graph.page_kind
  ; shadow_page_created_at_ms : int64
  ; shadow_page_updated_at_ms : int64
  ; shadow_recycled : bool
  }

type dependency_shadows =
  { shadow_blocks : dependency_block_shadow list
  ; shadow_pages : dependency_page_shadow list
  }

val empty_dependency_shadows : dependency_shadows
val equal_footprint : footprint -> footprint -> bool
val equal_delete_artifacts : delete_artifacts option -> delete_artifacts option -> bool

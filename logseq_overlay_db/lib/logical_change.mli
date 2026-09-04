module Graph = Logseq_db_types.Graph_types

val footprint_members
  :  Overlay_effect.footprint
  -> Graph.block_uuid list * Graph.page_uuid list * Types.structure_interest list

val bounded_summary
  :  maximum_items:int
  -> maximum_bytes:int
  -> block_uuids:Graph.block_uuid list
  -> page_uuids:Graph.page_uuid list
  -> structure_interests:Types.structure_interest list
  -> Types.logical_change_summary

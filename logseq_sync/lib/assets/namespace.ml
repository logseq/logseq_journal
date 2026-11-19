module Uuid = Logseq_db_types.Graph_types.Uuid

type account_scope = { managed_sync_origin : Uri.t; user_id : string }
type graph_scope = { account : account_scope; graph_id : Uuid.t }
type retirement_id = Logseq_db_types.Graph_types.Retirement_id.t
type asset_deletion = { scope : graph_scope; retirement : retirement_id }
let retirement_id_to_string = Logseq_db_types.Graph_types.Retirement_id.to_string
let retirement_id_of_string = Logseq_db_types.Graph_types.Retirement_id.of_string
let asset_deletion_scope deletion = deletion.scope
let asset_deletion_retirement deletion = deletion.retirement
let asset_deletion_reference ~scope ~retirement = { scope; retirement }
let of_identity (identity : Sync_dsl.Core.identity) =
  Result.map (fun graph_id ->
    { account = { managed_sync_origin = Uri.of_string identity.origin; user_id = identity.account }; graph_id })
    (Uuid.of_string identity.graph)

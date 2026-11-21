module Uuid = Logseq_db_types.Graph_types.Uuid

type account_scope = { managed_sync_origin : Uri.t; user_id : string }
type graph_scope = { account : account_scope; graph_id : Uuid.t }
type retirement_id = Logseq_db_types.Graph_types.Retirement_id.t
type asset_deletion
val retirement_id_to_string : retirement_id -> string
val retirement_id_of_string : string -> (retirement_id, string) result
val asset_deletion_scope : asset_deletion -> graph_scope
val asset_deletion_retirement : asset_deletion -> retirement_id
val asset_deletion_reference : scope:graph_scope -> retirement:retirement_id -> asset_deletion
val of_identity : Sync_dsl.Core.identity -> (graph_scope, string) result

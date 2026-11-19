module U : sig
  type observation =
    | Import_absent
    | Local_present
    | Metadata_present
    | Publication_acknowledged
    | Entity_cancelled
end

val inspect
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> (U.observation, Sync_dsl.Core.error) result

val apply_local
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, Sync_dsl.Core.error) result

val apply_metadata
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, Sync_dsl.Core.error) result

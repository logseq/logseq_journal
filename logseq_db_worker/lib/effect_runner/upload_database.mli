val inspect
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> ( Logseq_db_worker_pure_reducer.Asset_upload.observation
       , Logseq_db_worker_pure_reducer.Asset_upload.failure )
       result

val apply_local
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, Logseq_db_worker_pure_reducer.Asset_upload.failure) result

val apply_metadata
  :  ?on_diagnostic:(Logseq_db_types.Failure_diagnostic.t -> unit)
  -> Logseq_overlay_db.Database.t
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, Logseq_db_worker_pure_reducer.Asset_upload.failure) result

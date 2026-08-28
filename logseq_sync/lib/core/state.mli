val advance
  :  Logseq_db_types.Sync_checkpoint.t
  -> applied_server_t:int
  -> checksum:string
  -> (Logseq_db_types.Sync_checkpoint.t, string) result

val pause
  :  Logseq_db_types.Sync_checkpoint.t
  -> message:string
  -> (Logseq_db_types.Sync_checkpoint.t, string) result

let advance (checkpoint : Logseq_db_types.Sync_checkpoint.t) ~applied_server_t ~checksum =
  Logseq_db_types.Sync_checkpoint.create_full
    ~graph_id:checkpoint.graph_id
    ~schema:checkpoint.schema
    ~applied_server_t
    ~checksum
    ~status:Logseq_db_types.Sync_checkpoint.Active
    ~last_error:None
;;

let pause (checkpoint : Logseq_db_types.Sync_checkpoint.t) ~message =
  Logseq_db_types.Sync_checkpoint.create_full
    ~graph_id:checkpoint.graph_id
    ~schema:checkpoint.schema
    ~applied_server_t:checkpoint.applied_server_t
    ~checksum:checkpoint.checksum
    ~status:Logseq_db_types.Sync_checkpoint.Paused
    ~last_error:(Some message)
;;

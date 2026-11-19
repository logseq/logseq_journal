val remove_tree : string -> unit

val inspect
  :  verify:Snapshot_checksum.verifier
  -> check_current:(unit -> unit)
  -> scratch_bytes:int64
  -> maximum_frame_bytes:int
  -> directory:string
  -> encrypted:bool
  -> path:string
  -> expected_rows:int
  -> (Logseq_overlay_db.Types.Checksum.t, string) result

type verifier =
  check_current:(unit -> unit)
  -> scratch_bytes:int64
  -> encrypted:bool
  -> path:string
  -> (Logseq_overlay_db.Types.Checksum.t, string) result

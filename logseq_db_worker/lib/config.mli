(** Accepts Logseq graph schemas at version 65.33 or newer. *)
type compatibility_profile = Logseq_65_33_or_newer

type synced_bootstrap =
  { snapshot_path : string
  ; applied_server_t : int
  ; checksum : string option
  ; expected_rows : int
  }

type synced_e2ee =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; encrypted_graph_key : string
  }

type target =
  | Managed_sync of { base_url : string }
  | Snapshot of { token : Graph_types.Uuid.t }
  | Import_snapshot of { inbox_entry : string }
  | Synced_graph of
      { graph_id : Graph_types.Uuid.t
      ; graph_name : string
      ; e2ee : synced_e2ee option
      ; bootstrap : synced_bootstrap option
      }
  | Native_local_graph of
      { graph_name : string
      ; graph_dir : string
      }

type t =
  { application_support_directory : string
  ; target : target
  ; compatibility_profile : compatibility_profile
  ; response_budget_bytes : int
  ; default_page_size : int
  }

val create
  :  application_support_directory:string
  -> target:target
  -> compatibility_profile:compatibility_profile
  -> response_budget_bytes:int
  -> default_page_size:int
  -> (t, string) result

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

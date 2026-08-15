(** Accepts Logseq graph schemas at version 65.33 or newer. *)
type compatibility_profile = Logseq_65_33_or_newer

type target =
  | Snapshot of { token : Graph_types.Uuid.t }
  | Import_snapshot of { inbox_entry : string }
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

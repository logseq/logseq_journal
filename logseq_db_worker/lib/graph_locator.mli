type platform =
  | Desktop of { home_directory : string }
  | Ios of { application_data_directory : string }

type resolved =
  { graph_name : string
  ; graph_dir : string
  ; database_path : string
  }

type error =
  | Invalid_graph_name of string
  | Invalid_utf8
  | Path_escape
  | Symlink_escape
  | Basename_mismatch
  | Graph_directory_missing
  | Database_missing

val resolve : platform -> graph_name:string -> (resolved, error) result
val validate_native : graph_name:string -> graph_dir:string -> (resolved, error) result

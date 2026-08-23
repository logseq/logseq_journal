type schema =
  { major : int
  ; minor : int
  ; exact : bool
  }

type graph =
  { graph_id : Graph_types.Uuid.t
  ; name : string
  ; schema : schema
  ; encrypted : bool
  }

type mirror_status =
  | Missing
  | Downloading
  | Ready

type cache

val decode : string -> (graph list, string) result

val create_cache
  :  user_id:string
  -> base_url:string
  -> graphs:graph list
  -> selected_graph:Graph_types.Uuid.t option
  -> cache

val merge : cache -> graph list -> cache
val graphs : cache -> graph list
val user_id : cache -> string
val base_url : cache -> string
val selected_graph : cache -> Graph_types.Uuid.t option
val select : cache -> Graph_types.Uuid.t -> (cache, string) result
val mirror_status : cache -> Graph_types.Uuid.t -> mirror_status
val set_mirror_status : cache -> Graph_types.Uuid.t -> mirror_status -> cache
val to_yojson : cache -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (cache, string) result

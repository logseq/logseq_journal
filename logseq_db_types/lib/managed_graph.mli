type schema =
  { major : int
  ; minor : int
  ; exact : bool
  }

type t =
  { graph_id : Graph_types.Uuid.t
  ; name : string
  ; schema : schema
  ; encrypted : bool
  }

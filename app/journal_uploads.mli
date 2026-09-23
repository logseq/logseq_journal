module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Uuid = Logseq_db_types.Graph_types.Uuid

type t

type row =
  { id : string
  ; title : string
  ; message : string
  ; busy : bool
  ; retry : bool
  }

val empty : t
val sync : t -> (int * Uuid.t) option -> t
val notice : t -> Service.asset_scope -> Service.asset_notice -> t
val rows : t -> row list
val retry : t -> Uuid.t -> Service.request option

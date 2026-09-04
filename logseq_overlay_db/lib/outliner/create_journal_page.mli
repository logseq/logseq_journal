module Graph = Logseq_db_types.Graph_types

val identity
  :  mutation_id:Graph.Uuid.t
  -> page:Graph.page_uuid
  -> title:string
  -> journal_day:int
  -> string

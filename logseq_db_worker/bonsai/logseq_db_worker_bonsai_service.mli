val create
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> ( Logseq_db_worker.Config.t
       , Logseq_db_worker.Protocol.request
       , Logseq_db_worker.Protocol.response
       , Logseq_db_worker.Protocol.push )
       Worker.Service.t

val service
  : ( Logseq_db_worker.Config.t
      , Logseq_db_worker.Protocol.request
      , Logseq_db_worker.Protocol.response
      , Logseq_db_worker.Protocol.push )
      Worker.Service.t

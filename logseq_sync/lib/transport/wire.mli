module Dsl = Sync_dsl.Core
module Protocol = Logseq_sync_protocol.Sync_protocol

val submission : Dsl.Overlay.Types.submission_batch -> Protocol.Client.message
val head : Protocol.Server.message -> (Dsl.remote_head, Dsl.error) result

val pull
  :  limits:Dsl.limits
  -> since:Dsl.Overlay.Types.server_cursor
  -> Protocol.Server.message
  -> (Dsl.pull_result, Dsl.error) result

val push
  :  batch:Dsl.Overlay.Types.submission_batch
  -> Protocol.Server.message
  -> (Dsl.submission_reply, Dsl.error) result

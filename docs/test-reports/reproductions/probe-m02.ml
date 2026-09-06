#use "@@BOOTSTRAP@@";;
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol;;
#mod_use "@@CORE_SOURCE@@";;
#mod_use "@@CORE_HELPERS@@";;
module O = Logseq_overlay_db.Types;;
module H = Core_contract_helpers;;
let () =
  let submitted, connection = H.submitted_core () in
  let owner = Option.get submitted.Core.submission_owner in
  let pull connection = Core.Websocket_message (connection, Sync_protocol.Server.Pull_ok {t=1;checksum=Some "0123456789abcdef";txs=[{t=1;tx="{}";outliner_op=None}]}) in
  let incoming = Core.step submitted (pull connection) in
  assert(Option.is_some incoming.next.active_authoritative_batch);
  let deferred scope = Core.Authoritative_batch_deferred {scope;defer=O.Await_submission_outcome owner.batch_id} in
  let live = Core.step incoming.next (deferred connection.graph) in
  assert((Core.state live.next).snapshot.last_error=None);
  assert(Option.is_some live.next.deferred_authoritative_owner);
  let accepted = Core.step live.next (Core.Websocket_message (connection, Sync_protocol.Server.Tx_batch_ok {t=1;checksum=Some "0123456789abcdef"})) in
  assert(List.exists (function Core.Delegate (Core.Apply_outbox_transition {transition=O.Accept_group _;_}) -> true | _ -> false) accepted.effects);
  Printf.printf "M02 control: live owner tolerates deferred pull; batch-ok requests Accept_group.\n%!";
  let closed = Core.step submitted (Core.Websocket_closed(connection, Some "test disconnect before acknowledgement")) in
  assert(closed.next.submission_owner=None);
  let reconnecting = Core.step closed.next (Core.Foreground_changed {foreground=true;lifecycle_generation=1L}) in
  let next_connection = List.find_map (function Core.Run (Core.Start_websocket r) -> Some r.scope | _ -> None) reconnecting.effects |> Option.get in
  let reopened = Core.step reconnecting.next (Core.Websocket_opened next_connection) in
  let incoming = Core.step reopened.next (pull next_connection) in
  let failed = Core.step incoming.next (deferred next_connection.graph) in
  let snapshot = (Core.state failed.next).snapshot in
  assert(snapshot.sync_phase=Core.Failed);
  assert(snapshot.last_error=Some "authoritative defer owner mismatch");
  Printf.printf "M02 reconnect: owner=None; pull -> Await_submission_outcome -> Failed: %s.\n%!" (Option.get snapshot.last_error);
  let stale_ack = Core.step reopened.next (Core.Websocket_message (connection, Sync_protocol.Server.Tx_batch_ok {t=1;checksum=Some "0123456789abcdef"})) in
  assert(stale_ack.effects=[]);
  Printf.printf "M02 late acknowledgement from old connection is ignored. Reproduced.\n%!";
  let no_ack = Core.step live.next Core.Local_outbox_changed in
  assert(Option.is_some no_ack.next.submission_owner && Option.is_some no_ack.next.deferred_authoritative_owner);
  assert(not(List.exists (function Core.Delegate(Core.Apply_outbox_transition _) -> true | _ -> false) no_ack.effects));
  Printf.printf "M02 no acknowledgement: later local write requests inspection but cannot release submission/deferred owner.\n%!";;

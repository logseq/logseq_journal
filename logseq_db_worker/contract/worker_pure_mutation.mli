module Uuid = Graph_types.Uuid
module Data = Worker_pure_data

type mutation_command =
  | Save_block of
      { block : Uuid.t
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Insert_blocks of
      { parent : Uuid.t
      ; roots : Worker_pure_data.block_tree list
      ; preconditions : Worker_pure_data.preconditions
      }
  | Delete_blocks of
      { root : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Create_journal of
      { page : Uuid.t
      ; day : Worker_pure_day.t
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_task_status of
      { block : Uuid.t
      ; status : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Clear_task_status of
      { block : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_asset_reference of
      { block : Uuid.t
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }

type append_parameters = private
  {page:Uuid.t;day:Worker_pure_day.t;root:Data.append_node}
type append_intent
type mutation_intent
type durable_intent=Append_intent of append_intent|Mutation_intent of mutation_intent

val create_mutation : origin:Uri.t -> user:string -> graph:Uuid.t -> mutation_id:Uuid.t
  -> mutation_command -> (mutation_intent,string)result
val create_append : origin:Uri.t -> user:string -> graph:Uuid.t -> mutation_id:Uuid.t
  -> page:Uuid.t -> day:Worker_pure_day.t -> root:Data.append_node -> (append_intent,string)result
val mutation_intent_id : mutation_intent -> Uuid.t
val append_intent_id : append_intent -> Uuid.t
val mutation_command : mutation_intent -> mutation_command
val append_parameters : append_intent -> append_parameters
val mutation_id : durable_intent -> Uuid.t
val targets : durable_intent -> Uuid.t Rrbvec.t
val namespace : durable_intent -> string
val namespace_for_owner : origin:Uri.t -> user:string -> graph:Uuid.t -> string
val readback_target : durable_intent -> [`Page of Uuid.t|`Block of Uuid.t]

(** These are the original canonical v1 storage bytes, including logical owner
    and stable mutation identity. Restore never executes or replays an intent. *)
val encode : durable_intent -> string
val restore : origin:Uri.t -> user:string -> graph:Uuid.t -> string -> (durable_intent,string)result

type commit=private
  {mutation_id:Uuid.t;status:Data.local_status;generation:string;before:string;after:string}
type outcome=Committed of commit|Rejected of Error.t|Unknown
type recovery_item={intent:durable_intent;outcome:outcome}
type recovery_page={items:recovery_item Rrbvec.t;next:int64 option}
type original_point=private{generation:string;before:string;after:string}
val committed_point : durable_intent -> commit -> (original_point,string)result
val commit_bytes : commit -> int
val maximum_recovery_bytes : int
val recovery_page_bytes : recovery_page -> int
module For_worker:sig
  val commit : mutation_id:Uuid.t -> status:Data.local_status -> generation:string
    -> before:string -> after:string -> commit
end

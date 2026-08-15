type t =
  | Capture of
      { calendar_generation : int64
      ; command : Journal_graph_projection.capture
      }
  | Create_child of Journal_graph_projection.create_child
  | Update_source of Journal_graph_projection.update_source
  | Set_task_state of Journal_graph_projection.set_task_state
  | Delete_subtree of Journal_graph_projection.delete_subtree
  | Find_block of string
  | Load_feed of
      { before_day : int option
      ; day_limit : int
      ; blocks_per_day : int
      ; slot_limit : int
      ; request_generation : int64
      }
  | Load_day_blocks of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      ; limit : int
      ; request_generation : int64
      }
  | Load_detail of
      { block_id : string
      ; after : Journal_graph_projection.block_cursor option
      ; limit : int
      ; request_generation : int64
      }


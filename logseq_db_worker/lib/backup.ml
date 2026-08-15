type source =
  | Snapshot of Graph_types.Uuid.t
  | Native of
      { source_graph_dir : string
      ; owner : Ownership.t
      }

type t =
  { catalog : Snapshot.catalog
  ; source : source
  ; mutable recovery_token : Graph_types.Uuid.t option
  }

type error =
  | Snapshot_error of Snapshot.error
  | Ownership_error of Ownership.error

let create ~catalog ~source_token =
  { catalog; source = Snapshot source_token; recovery_token = None }
;;

let create_native ~catalog ~source_graph_dir ~owner =
  { catalog; source = Native { source_graph_dir; owner }; recovery_token = None }
;;

let create_native_recovery t ~source_graph_dir ~owner =
  match Ownership.revalidate owner with
  | Error error -> Error (Ownership_error error)
  | Ok () ->
    (try
       if not (String.equal (Unix.realpath source_graph_dir) (Ownership.graph_dir owner))
       then Error (Ownership_error Ownership.Identity_changed)
       else (
         let generation = Ownership.generation owner in
         match
           Snapshot.create_native_recovery_copy
             t.catalog
             ~source_graph_dir
             ~owner_generation:generation
         with
         | Error error -> Error (Snapshot_error error)
         | Ok token ->
           (match Ownership.revalidate owner with
            | Error error -> Error (Ownership_error error)
            | Ok () ->
              (match Snapshot.manifest_owner_generation t.catalog token with
               | Error error -> Error (Snapshot_error error)
               | Ok (Some actual) when String.equal actual generation -> Ok token
               | Ok None | Ok (Some _) ->
                 Error (Snapshot_error Snapshot.Manifest_mismatch))))
     with
     | Unix.Unix_error _ -> Error (Ownership_error Ownership.Identity_changed))
;;

let ensure t =
  match t.recovery_token with
  | Some token -> Ok token
  | None ->
    (match t.source with
     | Native { source_graph_dir; owner } ->
       (match create_native_recovery t ~source_graph_dir ~owner with
        | Error _ as error -> error
        | Ok token ->
          t.recovery_token <- Some token;
          Ok token)
     | Snapshot source_token ->
       (match Snapshot.create_recovery_copy t.catalog source_token with
        | Error error -> Error (Snapshot_error error)
        | Ok token ->
          t.recovery_token <- Some token;
          Ok token))
;;

let verify t token =
  match Snapshot.resolve t.catalog token with
  | Error error -> Error (Snapshot_error error)
  | Ok _resolved ->
    (match t.source with
     | Snapshot _ -> Ok token
     | Native { owner; _ } ->
       (match Ownership.revalidate owner with
        | Error error -> Error (Ownership_error error)
        | Ok () ->
          (match Snapshot.manifest_owner_generation t.catalog token with
           | Error error -> Error (Snapshot_error error)
           | Ok (Some generation)
             when String.equal generation (Ownership.generation owner) -> Ok token
           | Ok None | Ok (Some _) -> Error (Snapshot_error Snapshot.Manifest_mismatch))))
;;

let ensure_verified t = Result.bind (ensure t) (verify t)
let recovery_token t = t.recovery_token

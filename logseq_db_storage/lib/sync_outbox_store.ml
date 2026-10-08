let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

type row =
  { mutation_id : string
  ; sequence : int
  ; record : string
  }

type delta =
  { expected_revision : int
  ; revision : int
  ; upserts : row list
  ; deletes : string list
  }

let protect f =
  try f () with
  | exn -> Error (Printexc.to_string exn)
;;

let schema db =
  let columns = ref [] in
  Result.bind
    (rc_result db
       (Sqlite3.exec db "PRAGMA table_info(sync_outbox)" ~cb:(fun row _ ->
          columns := Option.get row.(1) :: !columns)))
    (fun () ->
       match List.rev !columns with
       | [ "position"; "record" ] -> Ok `Legacy
       | [ "mutation_id"; "sequence"; "record" ] -> Ok `Incremental
       | _ -> Error "unsupported sync outbox storage format")
;;

let payload_identity record =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string record in
  ( json |> member "mutation" |> member "mutationId" |> to_string
  , json |> member "sequence" |> to_int
  , json |> member "syncRevision" |> to_int )
;;

let validate_rows rows =
  let identities = Hashtbl.create (List.length rows) in
  let rec loop previous = function
    | [] -> Ok ()
    | (row : row) :: rest ->
      let id, sequence, revision = payload_identity row.record in
      if
        not (String.equal id row.mutation_id)
        || sequence <> row.sequence
        || revision <> 0
        || sequence <= previous
        || Hashtbl.mem identities id
      then Error "invalid incremental sync outbox identity or sequence"
      else (
        Hashtbl.add identities id ();
        loop sequence rest)
  in
  protect (fun () -> loop 0 rows)
;;

let read_revision db =
  protect (fun () ->
    Result.bind (schema db) (function
      | `Legacy -> Ok None
      | `Incremental ->
        let values = ref [] in
        Result.bind
          (rc_result db
             (Sqlite3.exec db "SELECT format_version, revision FROM sync_outbox_metadata"
                ~cb:(fun row _ ->
                  values := (Option.get row.(0), Option.get row.(1)) :: !values)))
          (fun () ->
             match !values with
             | [ "1", revision ] ->
               (match int_of_string_opt revision with
                | Some revision when revision >= 0 -> Ok (Some revision)
                | _ -> Error "invalid sync outbox revision")
             | _ -> Error "unsupported or missing sync outbox metadata")))
;;

let initialize_database db =
  rc_result
    db
    (Sqlite3.exec
       db
       "CREATE TABLE IF NOT EXISTS sync_outbox (position INTEGER PRIMARY KEY, record \
        TEXT NOT NULL)")
;;

let read_database db =
  protect (fun () ->
    Result.bind (schema db) (function
      | `Legacy ->
        let records = ref [] in
        Result.map (fun () -> List.rev !records)
          (rc_result db
             (Sqlite3.exec db "SELECT record FROM sync_outbox ORDER BY position"
                ~cb:(fun row _ -> records := Option.get row.(0) :: !records)))
      | `Incremental ->
        Result.bind (read_revision db) (fun _ ->
          let rows = ref [] in
          Result.bind
            (rc_result db
               (Sqlite3.exec db
                  "SELECT mutation_id, sequence, record FROM sync_outbox ORDER BY sequence"
                  ~cb:(fun row _ ->
                    rows :=
                      { mutation_id = Option.get row.(0)
                      ; sequence = int_of_string (Option.get row.(1))
                      ; record = Option.get row.(2)
                      } :: !rows)))
            (fun () ->
               let rows = List.rev !rows in
               Result.map (fun () -> List.map (fun row -> row.record) rows)
                 (validate_rows rows)))))
;;

let replace_database db records =
  let legacy =
    Result.bind (schema db) (function
      | `Legacy -> rc_result db (Sqlite3.exec db "DELETE FROM sync_outbox")
      | `Incremental -> Error "incremental sync outbox requires a revisioned write set")
  in
  match legacy with
  | Error _ as error -> error
  | Ok () ->
    let statement =
      Sqlite3.prepare db "INSERT INTO sync_outbox(position, record) VALUES(?, ?)"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         let rec insert position = function
           | [] -> Ok ()
           | record :: rest ->
             Sqlite3.Rc.check (Sqlite3.reset statement);
             Sqlite3.Rc.check (Sqlite3.bind_int statement 1 position);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 2 record);
             (match rc_result db (Sqlite3.step statement) with
              | Error _ as error -> error
              | Ok () -> insert (position + 1) rest)
         in
         try insert 0 records with
         | exn -> Error (Printexc.to_string exn))
;;

let upsert_rows db rows =
  let statement =
    Sqlite3.prepare db
      "INSERT INTO sync_outbox(mutation_id, sequence, record) VALUES(?, ?, ?) ON \
       CONFLICT(mutation_id) DO UPDATE SET sequence=excluded.sequence, record=excluded.record WHERE \
       sync_outbox.sequence<>excluded.sequence OR sync_outbox.record<>excluded.record"
  in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement)) (fun () ->
    let rec loop = function
      | [] -> Ok ()
      | row :: rest ->
        Sqlite3.Rc.check (Sqlite3.reset statement);
        Sqlite3.Rc.check (Sqlite3.bind_text statement 1 row.mutation_id);
        Sqlite3.Rc.check (Sqlite3.bind_int statement 2 row.sequence);
        Sqlite3.Rc.check (Sqlite3.bind_text statement 3 row.record);
        Result.bind (rc_result db (Sqlite3.step statement)) (fun () -> loop rest)
    in
    loop rows)
;;

let migrate_database db ~revision ~expected_records rows =
  protect (fun () ->
    Result.bind (validate_rows rows) (fun () ->
      Result.bind (rc_result db (Sqlite3.exec db "BEGIN IMMEDIATE")) (fun () ->
        let result =
          protect (fun () ->
            Result.bind (read_database db) (fun current_records ->
              if current_records <> expected_records
              then Error "sync outbox rows changed during restore"
              else
                Result.bind (read_revision db) (function
                  | Some current when current = revision -> Ok ()
                  | Some _ -> Error "sync outbox revision changed during restore"
                  | None ->
                    Result.bind
                      (rc_result db
                         (Sqlite3.exec db
                            "ALTER TABLE sync_outbox RENAME TO sync_outbox_legacy; \
                             CREATE TABLE sync_outbox(mutation_id TEXT PRIMARY KEY NOT NULL, \
                             sequence INTEGER UNIQUE NOT NULL CHECK(sequence>0), record TEXT NOT NULL); \
                             CREATE TRIGGER sync_outbox_sequence_immutable BEFORE UPDATE OF sequence \
                             ON sync_outbox WHEN NEW.sequence<>OLD.sequence BEGIN SELECT \
                             RAISE(ABORT, 'sync outbox sequence is immutable'); END; \
                             CREATE TABLE sync_outbox_metadata(singleton INTEGER PRIMARY KEY \
                             CHECK(singleton=1), format_version INTEGER NOT NULL CHECK(format_version=1), \
                             revision INTEGER NOT NULL CHECK(revision>=0))"))
                      (fun () ->
                         Result.bind (upsert_rows db rows) (fun () ->
                           rc_result db
                             (Sqlite3.exec db
                                (Printf.sprintf
                                   "INSERT INTO sync_outbox_metadata VALUES(1,1,%d); DROP TABLE sync_outbox_legacy"
                                   revision)))))))
        in
        let result = Result.bind result (fun () -> rc_result db (Sqlite3.exec db "COMMIT")) in
        match result with
        | Ok () -> Ok ()
        | Error _ as error -> ignore (Sqlite3.exec db "ROLLBACK"); error)))
;;

let apply_delta db delta =
  protect (fun () ->
    if delta.revision < delta.expected_revision
    then Error "sync outbox revision cannot regress"
    else
      Result.bind (validate_rows delta.upserts) (fun () ->
        let revision =
          if delta.revision = delta.expected_revision
          then (
            let statement = Sqlite3.prepare db
                "SELECT revision FROM sync_outbox_metadata WHERE singleton=1 AND format_version=1 AND revision=?" in
            Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement)) (fun () ->
              Sqlite3.Rc.check (Sqlite3.bind_int statement 1 delta.expected_revision);
              match Sqlite3.step statement with
              | Sqlite3.Rc.ROW -> Ok ()
              | Sqlite3.Rc.DONE -> Error "sync outbox revision conflict"
              | rc -> rc_result db rc))
          else (
            let statement = Sqlite3.prepare db
                "UPDATE sync_outbox_metadata SET revision=? WHERE singleton=1 AND format_version=1 AND revision=?" in
            Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement)) (fun () ->
              Sqlite3.Rc.check (Sqlite3.bind_int statement 1 delta.revision);
              Sqlite3.Rc.check (Sqlite3.bind_int statement 2 delta.expected_revision);
              Result.bind (rc_result db (Sqlite3.step statement)) (fun () ->
                if Sqlite3.changes db = 1 then Ok () else Error "sync outbox revision conflict")))
        in
        Result.bind revision (fun () ->
          let statement = Sqlite3.prepare db "DELETE FROM sync_outbox WHERE mutation_id=?" in
          let deleted =
            Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement)) (fun () ->
              List.fold_left
                (fun result id -> Result.bind result (fun () ->
                  Sqlite3.Rc.check (Sqlite3.reset statement);
                  Sqlite3.Rc.check (Sqlite3.bind_text statement 1 id);
                  rc_result db (Sqlite3.step statement)))
                (Ok ()) delta.deletes)
          in
          Result.bind deleted (fun () -> upsert_rows db delta.upserts))))
;;

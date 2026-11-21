module Asset = Logseq_db_types.Asset_descriptor
let download_version (asset : Asset.t) =
  match asset.source with Managed version -> version | External _ -> None
let lookup_versions (asset : Asset.t) =
  match asset.source with
  | External _ | Managed None -> []
  | Managed (Some remote) ->
    match asset.current_checksum with
    | None -> [remote]
    | Some checksum when checksum = remote.checksum -> [remote]
    | Some checksum ->
      match Asset.version ~checksum ~file_type:remote.file_type with
      | Ok current -> [current; remote]
      | Error _ -> [remote]

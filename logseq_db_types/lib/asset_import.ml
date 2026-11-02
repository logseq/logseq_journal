type t =
  { operation : Graph_types.Uuid.t
  ; asset : Graph_types.Uuid.t
  ; replace_reference : Graph_types.Uuid.t option
  ; target : Graph_types.Uuid.t
  ; local_mutation : Graph_types.Uuid.t
  ; metadata_mutation : Graph_types.Uuid.t
  ; source_file : string
  ; title : string
  ; file_type : string
  }

module Pure_intent = struct
  module Uuid=Graph_types.Uuid
  type source=t
  type error=Invalid of string|Wrong_namespace
  type t={namespace:string;source:source;encoded:string}
  type wire=
    {schema:int;namespace:string;operation:Uuid.t;asset:Uuid.t;target:Uuid.t;
     replace_reference:Uuid.t option;local_mutation:Uuid.t;metadata_mutation:Uuid.t;
     source_file:string;title:string;file_type:string}
  [@@deriving yojson]
  let maximum_bytes=16384
  let namespace_valid namespace=String.length namespace=64 && String.for_all(function '0'..'9'|'a'..'f'->true|_->false)namespace
  let create ~namespace (source:source)=
    let text ~maximum value=value<>"" && String.length value<=maximum
      && String.is_valid_utf_8 value && not(String.contains value '\000') in
    if not(namespace_valid namespace) || not(text ~maximum:8192 source.source_file)
       || not(text ~maximum:1024 source.title) || String.trim source.title=""
       || source.replace_reference=Some source.asset || Uuid.equal source.local_mutation source.metadata_mutation
    then Error(Invalid "Invalid immutable asset import source or identity") else
    Result.bind(Asset_descriptor.version ~checksum:(String.make 64 '0') ~file_type:source.file_type
      |> Result.map_error(fun message->Invalid message))(fun _->
      let wire={schema=1;namespace;operation=source.operation;asset=source.asset;target=source.target;
        replace_reference=source.replace_reference;local_mutation=source.local_mutation;metadata_mutation=source.metadata_mutation;
        source_file=source.source_file;title=source.title;file_type=source.file_type} in
      let encoded=wire_to_yojson wire |> Yojson.Safe.sort |> Yojson.Safe.to_string in
      if String.length encoded>maximum_bytes then Error(Invalid "Asset import payload exceeds its byte bound")
      else Ok{namespace;source;encoded})
  let restore ~namespace bytes =
    if String.length bytes>maximum_bytes then Error(Invalid "Asset import payload exceeds its byte bound") else
    try
      let json=Yojson.Safe.from_string bytes in
      Result.bind(Json_codec.decode ~maximum_bytes wire_of_yojson json |> Result.map_error(fun message->Invalid message))
        (fun wire->if wire.schema<>1 then Error(Invalid "Unsupported import source schema")
          else if wire.namespace<>namespace then Error Wrong_namespace else
          let source:source={operation=wire.operation;asset=wire.asset;target=wire.target;
            replace_reference=wire.replace_reference;local_mutation=wire.local_mutation;metadata_mutation=wire.metadata_mutation;
            source_file=wire.source_file;title=wire.title;file_type=wire.file_type} in
          Result.bind(create ~namespace source)(fun intent->
            if intent.encoded<>bytes then Error(Invalid "Asset import bytes are not canonical") else Ok intent))
    with Yojson.Json_error _ | Failure _ | Invalid_argument _->Error(Invalid "Invalid asset import bytes")
  let encode (intent:t)=intent.encoded
  let namespace (intent:t)=intent.namespace
  let source (intent:t)=intent.source
  let operation (intent:t)=intent.source.operation
end

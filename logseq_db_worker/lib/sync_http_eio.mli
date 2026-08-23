type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

val perform
  :  sw:Eio.Switch.t
  -> environment:Eio_unix.Stdenv.base
  -> Sync_http.request
  -> (response, string) result

val download
  :  sw:Eio.Switch.t
  -> environment:Eio_unix.Stdenv.base
  -> request:Sync_http.request
  -> destination:string
  -> maximum_bytes:int
  -> on_progress:(Sync_bootstrap.progress -> unit)
  -> (response, string) result

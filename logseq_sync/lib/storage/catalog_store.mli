val load
  :  application_support_directory:string
  -> user_id:string
  -> base_url:string
  -> (Catalog.cache option, string) result

val save : application_support_directory:string -> Catalog.cache -> (unit, string) result

val load
  :  application_support_directory:string
  -> user_id:string
  -> base_url:string
  -> (Sync_catalog.cache option, string) result

val save
  :  application_support_directory:string
  -> Sync_catalog.cache
  -> (unit, string) result

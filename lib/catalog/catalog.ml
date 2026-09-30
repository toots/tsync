open Tsync_core
open Tsync_store

let v =
  {
    Field_spec.backends =
      [
        ("local", Local.fields);
        ("s3", S3.fields);
        ("gcs", Gcs.fields);
        ("http-proxy", Http_proxy_client.fields);
      ];
    frontends =
      List.filter_map Fun.id
        [
          Catalog_fuse.entry;
          Catalog_file_provider.entry;
          Some ("android", Tsync_android.Android_options.fields);
          Some ("http-proxy", Tsync_http_proxy.Http_proxy_options.fields);
        ];
    presenting = ["fuse"; "file_provider"; "android"];
    linkless = ["local"];
  }

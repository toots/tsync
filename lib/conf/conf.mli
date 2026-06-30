type t = {
  client : S3_client.t;
  domain_name : string;
  domain_prefix : string;
  chunk_prefix : string;
  trash_prefix : string;
  versioning : bool;
  journal_prefix : string;
  version_key : string;
}

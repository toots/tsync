# Later

Possible improvements, not yet specified. Nothing here is normative. An item that is taken up moves
into the spec that owns it. Extensions keep their own lists at the end of each file.

## Shares

- **Immutable shares**: a link that serves its target as it was when shared, not as it is now. The
  manifest would name a version rather than a live key, and every unexpired share would be a root
  of collection ([gc §4.3](algorithms/gc.md#43-shares), [§5.3](algorithms/gc.md)), so its chunks
  outlive the file's own retention.
- **Replacing a token**: `tsync share --token=… --replace` re-points a caller-chosen token without
  a revoke first. Only a manifest naming the same domain may be replaced, with a conditional replace
  against the manifest read, after deleting the token's cached archive and preview image, which are
  named by token and would otherwise serve the old target. Replacing would relax the rule that a
  share never overwrites a manifest ([security-model §6.1](algorithms/security-model.md#61-token),
  [05 §4.11](05-ops-config.md)).

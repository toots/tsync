# FileProvider SDK facts for a macOS replicated extension (deployment target macOS 13+)

Compiled 2026-10-02.

## Sources and conventions

- **H** = header doc comment in the macOS 26.5 SDK, `FileProvider.framework/Versions/A/Headers/`, mirrored at
  `https://github.com/alexey-lysiuk/macos-sdk/tree/main/MacOSX26.5.sdk/System/Library/Frameworks/FileProvider.framework/Versions/A/Headers/`.
  The same repo carries 13.3, 14.5 and 15.5 SDKs for diffing.
  Header comments are the most authoritative source here, and are quoted verbatim.
- **Availability macros** (NSFileProviderDefines.h): V3 / V3_IOS = macOS 11.0; V3_1 = 11.3; V4_0 = 12.0; V4_1 = 12.3; V5_0 = 13.0; V2_V5 = 13.0; V6_0_IOS = 14.1; V7_0_IOS = 14.4; EXTERNAL_VOLUME / DESKTOP / V8_0 = 15.0; FEEDBACK = 15.4; SEARCH / SYNC_CONTROLS = **26.0**.
- **D** = developer.apple.com documentation, fetched through `https://developer.apple.com/tutorials/data/documentation/<path>.json`.
- **F** = Apple Developer Forums. "FE" = Frameworks Engineer, "DTS" = Developer Technical Support.
- Confidence: **High** = header or doc text; **Med** = Apple-engineer forum answer; **Low** = community report or inference.

---

## 1. Working set in replicated extensions

**What must the working set contain?**
- H, NSFileProviderReplicatedExtension.h, `materializedItemsDidChangeWithCompletionHandler` (macOS 11.0):
  > "Traversals of dataless directories by applications trigger an enumeration against the file provider extension; traversals of materialized directories do not. It is the responsability of the file provider extension to notify the system on remote changes of these files: there is no alternative cache invalidation mechanism."
  > "If the extension doesn't keep track of the materialized set, it will have to notify the system of all remote changes. In that case the working set is the entire dataset. The system may drop items whose parent isn't materialized, to avoid unnecessary disk usage."
- D, "Synchronizing the File Provider extension", https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension:
  > "To ensure that the system applies remote updates to local copies, the working set must also include all materialized items managed by the system when using a replicated file provider. If your file provider doesn't explicitly track materialized items, the working set must include all items (documents and directories) on your remote storage."
- H, NSFileProviderEnumerating.h, on `enumeratorForContainerItemIdentifier`: once a directory has been enumerated, "the directory and its children should be included in the working set."
- F 831371 (Systems Engineer, Jun 2026), https://developer.apple.com/forums/thread/831371: to shrink the working set, first "evict the folder on disk with `evictItem(withIdentifier:completionHandler:)` and after the eviction you can remove the children form the working set as they are not on disk anymore. Note that eviction can fail, so you should check for its success". Items removed from the working set are no longer searchable unless the provider adopts `NSFileProviderSearching` (macOS 26).
- FruitBasket sample, D https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions: "In this sample, the working set is the same as the item set in the root container (which includes every item under the root container, recursively)."

**Answer.** The working set's `enumerateItems` must return either the whole domain, or a superset of every item whose parent is materialized. Its `enumerateChanges` must report every change to any item in that set. The easy, documented option is "entire dataset", and the system drops items whose parent is not materialized. The trash also belongs in it: "Trashed items should remain in the working set; however, children of trashed directories should be removed from the working set" (H, NSFileProviderItem.h, `trashed`). **High.**

**Is signalEnumerator for other containers ignored?** Yes.
- H, NSFileProviderManager.h, `signalEnumeratorForContainerItemIdentifier`:
  > "When using NSFileProviderReplicatedExtension, only call this method with NSFileProviderWorkingSetContainerItemIdentifier. Other container identifiers are ignored. The system will automatically propagate working set changes to the UI, without explicitly signaling the containers currently being viewed in the UI."
- **Contradiction:** D "Synchronizing the File Provider extension" (section "Update the Local Copy") still tells providers to signal the matching item identifier and then the working set. That is the non-replicated model. The header wins. **High.**

**Are enumerateChanges and currentSyncAnchor called for ordinary directory enumerators?**
- F 831358 (FE, Jun 2026, accepted answer), https://developer.apple.com/forums/thread/831358: "`enumerateChanges` is indeed only ever used for the `workingSet` enumeration."
- F 831362 (Apple engineer, Jun 2026), https://developer.apple.com/forums/thread/831362: `currentSyncAnchor` is still called on folder enumerators, but "This is only useful for the working set because the folder enumerators don't use this value."
- F 831323 (FE, Jun 2026), https://developer.apple.com/forums/thread/831323:
  > "Normally, `enumerateItems` on a folder will only be called when the folder is initially materialized, and might be called a second time soon after that materialization. And `enumerateChanges` is the main source for keeping the system updated with changes happening remotely."
- **Answer.** Folder enumerators get `enumerateItems`, and they also get `currentSyncAnchor`, whose value is ignored. Returning any non-nil anchor, or the global one, is fine. They never get `enumerateChanges`. **Med.** The header's "change-based observation methods are … really required" note is generic and pre-dates replicated mode.
- Working set guarantees, from H on `enumeratorForContainerItemIdentifier`:
  > "The system guarantees that it has a single consumer for the working set. This means there will never be two concurrent enumerations of the working set and will always do forward progress: the system will only ask for changes from the last requested sync anchor or the last returned sync anchor and the extension should be prepared for it."
  > "The expiration of the sync anchor of the working set will cause a very expensive scan of all the items known by the system."
- **Race check.** If `NSExtensionFileProviderAppliesChangesAtomically` is not set, the system "will check if the enumeration of the item races against a call to createItemBasedOnTemplate, modifyItem, ... If a potential race is detected, the system will call itemForItemIdentifier in order to resolve the race." (same comment).
- `parentItemIdentifier` in working-set items must be the real parent, not `.workingSet` (H, NSFileProviderItem.h).

## 2. Sync anchors

- Size: "The size of a sync anchor should not exceed a combined 500 bytes." Pages: "The size of a page should not exceed 500 bytes." (H, NSFileProviderEnumerating.h, macOS 11).
  - Anchor overflow: "Sync anchor data is limited to 500 bytes. Setting a larger anchor has the same effect as calling finishEnumeratingWithError with an expired sync anchor error."
  - Page overflow: "Page data is limited to 500 bytes. Setting a larger nextPage interrupts the enumeration." **High.**
- `finishEnumeratingChangesUpToSyncAnchor:moreComing:` (H):
  > "It is expected that the sync anchor passed here be different than the sync anchor that the enumeration started at, unless the client was already up to date on all the changes on the server, and didn't have any pending updates or deletions. Additionally, if the client is up to date on all the changes on the server it should set moreComing to NO."
  - Returning the start anchor is therefore legal only with no changes and `moreComing:NO`. The docs do not say what happens if you return the same anchor with changes or with `moreComing:YES`. Expect a re-delivery loop. **High** for the rule, **unknown** for the misuse.
- Sequence (H, `currentSyncAnchorWithCompletionHandler`):
  > "request the current sync anchor (1) - enumerate items starting with an initial page - continue enumerating pages … until finishEnumeratingUpToPage: is called with nextPage set to nil - enumerate changes starting from the sync anchor returned in (1), until finishEnumeratingChangesUpToSyncAnchor: is called with the latest sync anchor. If moreComing is YES, continue enumerating changes, using the latest sync anchor returned. If moreComing is NO, stop enumerating. - When the extension calls … signalEnumeratorForContainerItemIdentifier … the system will again enumerate changes, starting at the latest known sync anchor from finishEnumeratingChangesUpToSyncAnchor."
- `syncAnchorExpired`, as described in H, NSFileProviderChangeObserver:
  > "If the enumeration fails with NSFileProviderErrorSyncAnchorExpired, we will drop all cached data and start the enumeration over starting with sync anchor nil."
  - The error enum says: "The value of the sync anchor is too old, and the system must re-sync from scratch".
  - In replicated mode the working set's expiry causes "a very expensive scan of all the items known by the system", and FE (831323) adds that "the system might be forced to reevaluate the content of all the folders".
  - **Docs silent** on whether items not re-enumerated after an expiry are deleted. Treat a full re-enumeration as authoritative for safety: every live item must be re-sent. **Med.**
- What `finishEnumeratingWithError` does for each error type. Documented only for `enumeratorForContainerItemIdentifier` and by analogy for the other calls (H):
  - `noSuchItem` → "the system will consider the item has been deleted and attempt to delete the item from disk."
  - `notAuthenticated` / `serverUnreachable` → "present an appropriate error message and back off until the next time it is signalled."
  - Anything else, including crashes → "considered to be transient and will cause the enumeration to be retried."
  - Trash container when trash is unsupported → `NSCocoaErrorDomain` / `NSFeatureUnsupportedError`.
  - **Docs silent** on the exact retry schedule. **High** for the categories.
- Recovering lost sync state (H, `reimportItemsBelowItemWithIdentifier`):
  > "In case the extension has lost its synchronisation state but is still able to guarantee the stability of the itemIdentifiers, it should make sure that querying the working set enumerator with an anchor that predates the synchronisation loss will cause a NSFileProviderErrorSyncAnchorExpired error."

## 3. Pages, sort order, suggested sizes

- `NSFileProviderInitialPageSortedByDate` / `…ByName` (macOS 11). H, `enumerateItemsForObserver:startingAtPage:`:
  > "The sort order specified in the initial page is important even if the enumeration results will actually be sorted again before display. If results are sorted correctly across pages, then the new results will be appended at the bottom … Otherwise results from the second page might be inserted in the results from the first page, causing bizarre animations."
  - So sort order matters only for UI. It is not a correctness requirement, and the replicated system re-sorts. **High** (text), **Med** (that it is harmless to ignore).
- The materialized-set enumerator ignores the sort constants. Pass `[NSData new]` (H, NSFileProviderManager.h).
- `suggestedPageSize` (observer, optional, macOS 11): "The system enforces a maximum of 100 times the suggested size."
- `suggestedBatchSize` (change observer):
  > "In case the enumerator has already more than suggestedBatchSize pending changes ready to enumerate, it is suggested it split the list of changes into several batches. If the enumerator does not have suggestedBatchSize ready to enumerator, the enumerator should finish immediately and not wait for more incoming changes … when the device reboots, enumerations will resume from the latest known sync anchor. … The system enforces a maximum of 100 times the suggested size."
  - Both are optional properties, so check `respondsToSelector`. **High.**
- Execution time for a page or batch: "not expected to take more than a few seconds … recommended to either report an error (for instance NSFileProviderErrorServerUnreachable) or return everything that is readily available and wait for the enumeration of the next page." **High.**
- `pageExpired` == `syncAnchorExpired` (same code, -1002): "The value of the page token is too old, and the system must re-sync from scratch". **Docs silent** on whether the system restarts from the initial page; presumably it does. See Q18.

## 4. Item versions

- `NSFileProviderItemVersion` (macOS 11). "Components are limited to 128 bytes in size." (H)
- `contentVersion` (H, NSFileProviderItem.h):
  > "if the contentVersion changes, - the system assumes that the contents have changed and will trigger a redownload if necessary. The exception to this is the case where the extension accepts a content sent by the system when replying to a createItemBasedOnTemplate or modifyItem call with shouldFetchContent set to NO. - the thumbnail cache is invalidated. Note that the resource fork of the file is considered content".
- `metadataVersion`:
  > "The system will store this version, but otherwise ignore it: - metadata changes on an item will be applied even if the metadataVersion remains unchanged - if the metadata version changes without any corresponding observable changes … the system will simply store the updated metadata version (to return it as the base version of a possible future change request)."
- A createItem/modifyItem completion that returns a new `contentVersion` with `shouldFetchContent = NO` means "I accepted your bytes, this is their version". No re-fetch happens.
  - To get the server's bytes put on disk instead, H says: "If the content of the item as described by createdItem does not match the content from url, the provider should set shouldFetchContent in the completion handler. The content from the provider will then be fetched and propagated to disk."
  - The conflict section of `modifyItem` describes another way: return the new remote `contentVersion`, and "The system will subsequently call fetchContents to retrieve the new contents and replace them on disk." **High.**
- Any field that differs from the template and is not in `stillPendingFields` is written to disk: "If a field in the returned createdItem does not match the itemTemplate, and is not in the list of stillPendingFields, the value from the createdItem will be propagated to the disk." **High.**
- `baseVersion` (H, modifyItem):
  > "This baseVersion describes the latest version of the file which was reflected on disk. This parameter can be used to detect conflicts with remote edits. … The extension informs the system of how it wishes to resolve the conflict by returning the resolved metadata on the completion handler."
  - It may contain `beforeFirstSyncComponent` (macOS 12.0) "in case there has never been a version for which the item on disk and the item in the provider were known to be in sync."
- Recommended conflict pattern, F 776884 (Apple engineer, Mar 2025, accepted), https://developer.apple.com/forums/thread/776884:
  > "In the implementation of that call, you can detect the conflict, return the new state for that itemIdentifier on the completion handler (including changing the `filename` … the system will propagate the change back to disk), as well as return a new `contentVersion`, so that the system fetches the remote contents that you've assigned to that existing identifier. And then also push a working set change for the conflict copy that you generate in the `modifyItem` completion handler, with the new itemIdentifier, and the contentVersion corresponding to the user's locally edited version."
  - This is **Med**. Note that it makes the *remote* version keep the identifier while the local edit becomes a new item, created from extension-side bytes.
- Deletion conflict: `deleteItem` receives `baseVersion`. If it is out of date, return `deletionRejected` → "the system [will] re-create the deleted item on disk based on the latest metadata available from the extension." **High.**
- Remote delete versus local edit: the system re-creates the item via `createItem` with `NSFileProviderCreateItemDeletionConflicted` (macOS 11.3). "The itemVersion will also be set to the last itemVersion of the item that was made available on disk before the item was edited locally. If such a conflict happens on a dataless item on disk, the item will be immediately deleted". **High.**
- **macOS 26 only** (SYNC_CONTROLS):
  - `NSFileProviderModifyItemFailOnConflict`, opt-in via `NSExtensionFileProviderSupportsFailingUploadOnConflict` = YES. The provider should "fail the modification if the baseVersion does not match the version on the server. It will be up to the system to merge the conflict and call modifyItem again with an updated baseVersion."
  - The error to return is `NSFileProviderErrorLocalVersionConflictingWithServer` (-2015), also 26.0.
  - `NSFileProviderModifyItemIsImmediateUploadRequestByPresentingApplication`: "require the upload to complete before calling the completion handler."
  - None of these exist on macOS 13–15. **High.**
- Directory versions: **docs silent** beyond the general rules.
  - A remote metadata change to a folder does not re-enumerate it. F 711951 (2022, unanswered) reports that changed `childItemCount` or `contentModificationDate` does not trigger a refresh.
  - Children are refreshed only via working-set changes for the children.
  - A sensible choice is a stable directory `contentVersion` (e.g. constant), with `metadataVersion` bumped on rename or move. **Low** (inference).
- Thumbnails are cached until `contentVersion` changes (H, `NSFileProviderThumbnailing`).

## 5. Errors

- Allowed domains (every replicated method, H):
  > "Errors must be in one of the following domains: NSCocoaErrorDomain, NSFileProviderErrorDomain. For errors which can not be represented … construct an NSError with domain NSCocoaErrorDomain and code NSXPCConnectionReplyInvalid. The extension should set the NSUnderlyingErrorKey".
  - A POSIX or custom-domain error is therefore illegal. **High.**
- "Resolvable" (throttled) errors. `signalErrorResolved:` (macOS 11) supports:
  > "NSFileProviderErrorNotAuthenticated - NSFileProviderErrorInsufficientQuota - NSFileProviderErrorServerUnreachable - NSFileProviderErrorCannotSynchronize - NSFileProviderErrorExcludedFromSync"
  - "Calling this method will cause the system to cancel throttling on every item which has been throttled due to the given error."
  - FruitBasket D: "Among the predefined errors, the following four are resolvable: notAuthenticated, serverUnreachable, insufficientQuota, cannotSynchronize. When encountering a resolvable error, the system throttles the operation until something … calls signalErrorResolved … Any other error, including crashes of the extension process, is transient, and causes the system to retry".
  - Per method, "back off until the next time it is signalled" is listed for:
    - item(for:) and fetch: notAuthenticated, serverUnreachable.
    - create and modify: notAuthenticated, cannotSynchronize, excludedFromSync.
    - delete: notAuthenticated, serverUnreachable, cannotSynchronize.
  - "Signalled" means `signalErrorResolved` and, for enumeration, probably also `signalEnumerator`. The docs do not say which signal lifts which throttle. Call `signalErrorResolved` for each code and signal the working set. **High** for the list, **Low** on the exact scope.
  - **Contradiction (F 803669, Oct 2025, unresolved)**, https://developer.apple.com/forums/thread/803669: a developer returned `notAuthenticated` from `modifyItem` and saw it "called multiple times with retry backoff intervals" rather than a global stop. Throttling appears to be per item with backoff, not a domain-wide latch. **Low/Med.**
- `cannotSynchronize` (-2005) from create/modify is near-permanent (H):
  > "syncing that item is definitively broken. The system will not retry syncing those items, until either: * The operating system has been updated. * The FileProvider extension has been updated. * The item is modified on disk."
  - `signalErrorResolved(cannotSynchronize)` is the only escape. Never use it for a transient daemon outage. **High.**
- Other errors: "considered to be transient and will cause the [operation] to be retried." **Docs silent** on the backoff schedule.
- "Provider process temporarily unavailable" (our daemon down):
  - There is no dedicated provider-side code. `providerDomainTemporarilyUnavailable` (-2012, macOS 14.1) is "Returned by the system", not by the provider.
  - Options:
    - (a) `serverUnreachable`: user-visible "can't connect" message, backoff until signalled, so the app must `signalErrorResolved(serverUnreachable)` and signal the working set when the daemon is back.
    - (b) A generic transient Cocoa error, e.g. `NSXPCConnectionReplyInvalid` with an underlying error: silent automatic retry.
  - Recommendation: (a) for a long outage, (b) for a brief one. **Med** (inference from the headers).
- `noSuchItem` from `item(for:)`:
  > "the system will consider the item has been removed from the domain and will attempt to delete it from disk. In case that deletion fails because there are local changes on this item, the system will re-create the item using createItemBasedOnTemplate."
  - Dangerous if returned spuriously, e.g. when the daemon has not loaded yet. **High.**
  - `noSuchItem` from createItem means the *parent* is missing → "the system will attempt the re-create the parent directory".
  - From modifyItem it may name the missing parent.
- `filenameCollision`: build it with `+[NSError fileProviderErrorForCollisionWithItem:]`, i.e. attach the colliding existing item.
  - H createItem: "If the error is returned, the system will try to resolve the collision by itself by bouncing away one of the items (renaming the item). … When the collision is resolved, the system will call createItemBasedOnTemplate again."
  - The error enum adds that collision includes "a filename differing only in case". **High.**
- `excludedFromSync` (-2010, macOS 13.0), from create or modify:
  > "it causes the item to be excluded from sync. The system will ensure that the item (and any descendents…) are downloaded, and then issue a deleteItem call to the provider for the item. The system will call createItemBasedOnTemplate for the item, whenever the item's metadata changes on disk."
  - Re-evaluate with `signalErrorResolved(excludedFromSync)`.
  - To exclude a previously synced item, call `requestModificationOfFields:…` and return the error from the resulting `modifyItem`. **High.**
- `directoryNotEmpty` (-1007): required for a non-recursive delete of a non-empty directory. It may also be used when some children cannot be deleted in a recursive delete. The system re-creates the item from the provider's latest metadata. **High.**
- `deletionRejected` (-1006): built with `fileProviderErrorForRejectedDeletionOfItem:`. The item is re-created on disk. **High.**
- Deleting an unknown item → report success. **High.**
- `versionNoLongerAvailable` (-2009, macOS 12.3):
  > "the version for this item is definitively unavailable. It is intended to be returned by fetchPartialContentsForItemWithIdentifier, when NSFileProviderFetchContentsOptionsStrictVersioning is set".
  - The reader then gets ESTALE, and a retry requests the new version. **High.**
- Read permission: `NSCocoaErrorDomain` / `NSFileReadNoPermissionError` from fetch is shown to the user. **High.**
- Refusing an import: return `nil` item with no error from createItem. The source is **deleted from disk** (recursively for a directory). Dangerous. **High.**

## 6. Contents transfer

- `fetchContents` (H, macOS 11):
  > "The retrieved content at `fileContents` URL must be a regular file on the same volume as the user-visible URL. A suitable location can be retrieved using -[NSFileProviderManager temporaryDirectoryURLWithError:]. The system clones and unlinks the received fileContents. The extension should not mutate the corresponding file after calling the completion handler. If the extension wishes to keep a copy of the content, it must provide a clone of the that content as the URL passed to the completion handler."
  > "In case the extension or the system crashes between the moment the completion handler is called and the moment the system unlinks the file, the file may unexpectedly still be on disk the next time an instance of the extension is created. The extension is then responsible for deleting that file."
  - "The system takes ownership of the item and will move it out of the sandbox of the provider."
  - Any location works if it is a regular file on the same volume. The temporary directory is merely "suitable". An App Group container file on the same volume is acceptable by this wording.
  - The system **unlinks** the file, so never hand over a daemon cache file. Hand over an APFS clone (`clonefile`). **High.**
  - The returned item's version "is assumed to be identical to what was requested". `requestedVersion` "is currently always set to nil". **High.**
- create/modify URL (H):
  > "The file at `url` is owned by the system and is unlinked after the completion handler is called. If the extension wishes to keep access to the content of file after calling the completion handler, it should clone the file in its container."
  - The URL is valid until the completion handler is called. Clone it before completing if bytes are uploaded later. **High.**
  - `url` is nil for folders, and for a dataless file during reimport (`mayAlreadyExist`). Symlinks come via `symlinkTargetPath`.
- "The filename and contents fields should be synced together. If synced independently, files may appear corrupted on other devices". **High.**
- Completing before the upload ends:
  - H modifyItem: "The progress returned by modifyItem is expected to include the upload progress if any, even if the provider chose to call the completion handler before the upload finishes. For example, the provider might decide to call the completion handler as soon as the metadata have been stored in a local database."
  - H item `uploaded`: "If you choose to finish uploading items after calling the completion handler of creteItem/modifyItem, you must set the uploaded flag to false, in order for the item to be excluded from eviction."
  - The flip to `isUploaded = YES` is then reported through the working set. **High** that this is allowed on macOS.
  - **Contradiction, F 836161 (Apple engineer, Jun 2026)**, https://developer.apple.com/forums/thread/836161:
    > "the design of NSFileProviderReplicatedExtension strongly prefers you to scope uploads to the lifetime of the createItem/modifyItem calls. I do not recommend setting the isUploaded flag manually - allow the system to manage this state via the result of createItem/modifyItem calls."
  - The engineer also says the pattern is impossible on iOS. Completing early also bypasses `NSExtensionFileProviderUploadPipelineDepth`. **Med.**
- Execution time: uploads "the system will grant enough time … if content is passed", and metadata-only calls are "expected to completed within a few seconds". The system cancels the progress if the call stalls. **High.**

## 7. NSFileProviderPartialContentFetching

- Availability: **macOS 12.3** (V4_1). `KnownSparseRanges` "is not functional prior to macOS 13.3". **High.**
- `fetchPartialContentsForItemWithIdentifier:version:request:minimalRange:aligningTo:options:completionHandler:(url, item, retrievedRange, flags, error)`, H:
  > "The implementation can provide any properly aligned range that covers the requested range (including the entire item). … The location … should be a multiple of this value … The length … should be a multiple of this value, with an exception for the end of the file, checked against the documentSize attribute … The alignment value should not be expected to be stable across reboots. It is guaranteed by the system to be a power of two. … fill in fetchedRange with either the requestest range, <location, length>, or indicate full materialization with, <0, file size>."
  > "The fetched range must be stored in this file at the same offset as the range indicates. … The system only requires the file to be at least as large as the end of the fetched range."
- Version: "This version will always be specified by the system … The system tolerates a version mismatch for the first materialization of a fully dataless file (strictVersion=NO)."
  - With `StrictVersioning` the provider fails with `versionNoLongerAvailable`.
  - Otherwise: "If some content is returned, the item must have the corresponding version. The system will detect any mismatch and handle it as a remote update."
- Flags: `NSFileProviderMaterializationFlagsKnownSparseRanges` → mark the whole file materialized. It is ignored unless the range is [0, EOF].
- Interaction: "If this protocol is not implemented the system defaults to fetchContentsForItemWithIdentifier."
  - `requestDownloadForItemWithIdentifier:requestedRange:` with a real range calls `fetchPartialContents`. `NSMakeRange(NSNotFound, 0)` means a full download.
  - "evictItemWithIdentifier … must be called on a partially materialized file before requesting an extent to be downloaded from a later version of the file."
  - **Docs silent** on contentPolicy interplay; presumably eager policies call the full fetch. Same pipeline depth and file-ownership rules as fetchContents.
- Reported risk: the VFS watchdog kills reads that stall repeatedly on partial fetches (forum search summary). Keep partial fetches fast. **Low.**

## 8. Content policy, eviction, pinning

- `NSFileProviderContentPolicy` and `-[NSFileProviderItem contentPolicy]`: **macOS 13.0** (V5_0_IOS). Values (H):
  - `Inherited`: "This is the default policy on every item other than the root."
  - `DownloadLazily`: "Download this item lazily (i.e when it is read) if it is dataless. Download remote content updates eagerly if this file is not dataless. Allow eviction on low disk pressure and other triggers. This is the default policy on the root on macOS."
  - `DownloadLazilyAndEvictOnRemoteUpdate`: "Evict the file upon remote content update." This is the default on the root on iOS.
  - `DownloadEagerlyAndKeepDownloaded`: "Download this item eagerly (i.e before it is read.) Keep downloading remote updates eagerly. Prevent eviction on low disk pressure and other triggers. When an item with the inherited policy is moved into a folder with this policy, the system will automatically schedule a download."
- Scope: the policy is per item and inherited down the tree. There is **no** per-domain property; set it on the root item for a domain-wide default. **High.**
- Is it the native "keep offline / pin"? Yes. F 762894 (Apple engineer, Aug 2024), https://developer.apple.com/forums/thread/762894: "requestDownload enqueues the item for downloading at a later time, dependent on device conditions. You can declaratively configure the download policy … Use the `.downloadEagerlyAndKeepDownloaded` option to ensure that the item is kept downloaded on the device." **Med/High.**
  - A pinned item cannot be evicted (Nextcloud docs agree).
  - The provider must store pin state server-side or locally, and re-publish the item with the new policy through the working set.
  - **Docs silent** on a system Finder "Keep Downloaded" menu for third-party providers. Use a custom action.
- `NSFileProviderItemCapabilitiesAllowsEvicting` is **deprecated macOS 11.0–13.0**: "use NSFileProviderContentPolicy instead".
  - Pre-13 rule: "If this capability is not present, the item will never be evicted."
  - On 13+, eviction is governed by the content policy. **Docs silent** on whether the flag is still read; it is harmless to set it.
  - `NSExtensionFileProviderAllowsUserControlledEviction` = NO in the Info.plist NSExtension dict "only suppress[es] the user's ability to evict the item in the UI (but retain the ability of the OS or the provider's program to evict items)". **High.**
- `evictItemWithIdentifier:` (macOS 11.0):
  - Files are made dataless. Directories are evicted recursively, then made dataless.
  - It stops at the first non-evictable child with `nonEvictableChildren` (-2006), with `underlyingErrors`.
  - Errors: `unsyncedEdits` (-2007), `nonEvictable` (-2008, "marked as non-purgeable by the provider", i.e. a keep-downloaded policy), EBUSY (open fds), EMLINK (hard links), other POSIX errors.
  - **Discrepancy:** the D page says local changes fail "with an NSFileWriteNoPermissionError" error, while the header says `unsyncedEdits`. Handle both. **High.**
  - Reported: EBUSY with no visible open file (F 739295). **Low.**
- `requestDownloadForItemWithIdentifier:requestedRange:` (**macOS 13.0**):
  > "The completion handler is called when the system acknowledges the download request … The system will then call -fetchContentsForItemWithIdentifier at the earliest convenient time. … This method cannot be used to download directories recursively. When invoked on a dataless directory, it will trigger an enumeration of the directory, causing a materialization of the directory one level down only."
  - Swift name: `requestDownloadForItem(withIdentifier:requestedRange:)`. **High.**

## 9. Domain lifecycle

- `addDomain`: "If a domain with the same identifier already exists, `addDomain` will update the display name and hidden state of the domain and succeed. … If that location already exists on disk this call will fail with the code NSFileWriteFileExistsError." The identifier must not contain `/` or `:`. **High.**
- Removal modes, `removeDomain:mode:completionHandler:(preservedLocation, error)` (**macOS 12.0**):
  - `RemoveAll` (0): "Don't keep any files".
  - `PreserveDirtyUserData` (1): "keeps the at least all the dirty corresponding user data around".
  - `PreserveDownloadedUserData` (2): "keeps all the downloaded corresponding user data around".
  - `preservedLocation` is the URL of the preserved data. It is nullable; presumably nil when nothing was preserved (**docs silent**). **High.**
- Re-adding after preserve: **docs silent**. To take over a directory, use `importDomain:fromDirectoryAtURL:` (macOS 11):
  > "That directory will be moved away, its ownership being taken by the system. From this point, your extension's createItemFromTemplate method will be called for every item found in the directory with the special NSFileProviderCreateItemMayAlreadyExist option."
  - It fails with NSFileWriteFileExistsError if the domain exists. **High.**
- `reimportItemsBelowItemWithIdentifier:` (macOS 11):
  > "the system will trigger a scan of any data that is cached on disk and call createItemBasedOnTemplate with the special NSFileProviderCreateItemMayAlreadyExist option so that the extension can specify the new itemIdentifier for those items. The provided item identifier is inclusive".
  > "In some circumstances, in particular in case the requested item is the root item, calling reimport will cause the system to stop the extension process. … When called on the root item, reimport will cause the system to rebuild its backing store for the domain."
  > "If the requested item has no on-disk representation, the completion handler will be called with a NSFileProviderErrorNoSuchItem error."
  - At the end, `importDidFinishWithCompletionHandler:` is called. Reimport may also be "started by the system independently from any request by the provider". Detect it via `NSFileProviderDomain.backingStoreIdentity` (macOS 12). **High.**
  - `mayAlreadyExist` guidance:
    > "The Extension should assess whether the item could actually be a disk representation of an already existing item. … attempts assessment methods for each item in order from cheapest to most expensive".
    - If no match and no content: "you should return a nil item if you are not able to match". **Careful:** a nil item normally deletes the on-disk source, so data loss is possible. **High.**
- Disconnect (macOS 11.0, V3): `disconnectWithReason:options:` / `reconnectWithCompletionHandler:`. `NSFileProviderManagerDisconnectionOptionsTemporary`: "A temporary disconnection would be used during e.g. an update; a non-temporary disconnection would be used in preparation of a log-out."
  - `isDisconnected`: "the user continues to be able to browse the domain's contents, but the extension doesn't receive updates on modifications to the files, nor is it consulted to update folder's contents."
  - The macOS 15 external-volume text adds: "Non-downloaded files in the domain will not be downloadable, and file edits will not be synced up."
  - It is documented for updates and log-out, **not** for "backend temporarily offline". `serverUnreachable` + `signalErrorResolved` is the documented offline path. Do not disconnect for network blips. **High** (text), **Med** (recommendation).
- Domain properties:
  - `supportsSyncingTrash`: macOS 13.0, "defaults to YES". With NO, "the system will decide how to handle the trashing operation (not guaranteed by API contract)".
  - `hidden`: read-write, macOS 11. "Typically, this can be used for dry-run migration. The files are still on disk though."
  - `userEnabled`: read-only, macOS 11. The user's toggle in System Settings. The system returns `domainDisabled` (-2011, macOS 13).
  - `testingModes` (macOS 11.3): `AlwaysEnabled`, `Interactive`. Both require the `com.apple.developer.fileprovider.testing-mode` entitlement. Interactive "does not support removing this mode".
  - `replicatedKnownFolders` / `supportedKnownFolders`: macOS 15 (Desktop & Documents). `backingStoreIdentity`: macOS 12. `userInfo` / `volumeUUID` / `initWithDisplayName:userInfo:volumeURL:`: macOS 15.
  - `supportsStringSearchRequest`: macOS 26. **High.**
- Manager calls:
  - `waitForStabilizationWithCompletionHandler:` (macOS 11): "wait until it is caught up with the file system's changes up to the time of the call, then wait until it is caught up with the provider's changes … useful to enforce a consistent state for testing."
  - `waitForChangesOnItemsBelowItemWithIdentifier:` (macOS 11): waits for disk changes below the item to be acknowledged. It ignores items moved in, so it is callable inside modifyItem. It returns immediately for non-directories. It fails with `cannotSynchronize` plus `NSFileProviderErrorItemKey`.
  - `getUserVisibleURLForItemIdentifier:` (macOS 11): a security-scoped URL. Use file coordination. "The caller should not try to manipulate files in the user visible location."
  - `temporaryDirectoryURLWithError:`: see Q19.
  - `stateDirectoryURLWithError:` (macOS 15): per domain, same volume, "Removing the domain will remove the corresponding directory along with it."
  - `requestModificationOfFields:forItemWithIdentifier:options:` (macOS 13). **High.**
- `providerNotFound` (-2001, "The application cannot be used right now.") at addDomain. Forum causes (**Low/Med**, community-resolved):
  - Extension not sandboxed after embedding.
  - `codesign --deep` re-signing the appex with the app's entitlements.
  - Missing `$(TeamIdentifierPrefix)` in `NSExtensionFileProviderDocumentGroup`.
  - Wrong-team provisioning profile.
  - The app not registered with LaunchServices / PluginKit.
  - F 702971 https://developer.apple.com/forums/thread/702971, F 729740 https://developer.apple.com/forums/thread/729740.
  - Related codes: `olderExtensionVersionRunning` (-2003), `newerExtensionVersionFound` (-2004), `providerTranslocated` (-2002), `applicationExtensionNotFound` (-2014, macOS 14.1).

## 10. App ↔ extension communication

- Documented FileProvider channel: `NSFileProviderServicing` / `supportedServiceSourcesForItemIdentifier:` (macOS 11) returns `NSFileProviderServiceSource` objects.
  - Each vends an `NSXPCListenerEndpoint` from an anonymous listener.
  - Clients call `-[NSFileManager getFileProviderServicesForItemAtURL:]`, or `-[NSFileProviderManager getServiceWithName:itemIdentifier:]` (**macOS 13.0**).
  - `restricted` (macOS 13): "can only be accessed by processes that can manage the domain".
  - This direction is client → extension, and it launches the extension. **High.**
- `NSFileProviderManager` usable from: "the extension - the main app containing the extension - sibling extensions … - executables contained in the main app bundle (on macOS only)". Those executables need a bundle ID prefixed by the app's, and access to the document group. **High.**
- Unix domain socket in an App Group container from a sandboxed appex:
  - D, App Groups Entitlement, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups:
    > "Apps within a group can communicate with other members in the group using IPC mechanisms including Mach IPC, XPC, POSIX semaphores and shared memory, and UNIX domain sockets. In macOS, use app groups to enable IPC communication between two sandboxed apps, or between a sandboxed app and a nonsandboxed app."
    - UNIX domain sockets: "The path to the socket needs to be in your app group container, and the name of the socket is limited to SOCK_MAXADDRLEN characters, which includes two bytes that are reserved for sun_len and sun_family."
  - Quinn (DTS), F 788364 (Jun 2025), https://developer.apple.com/forums/thread/788364: "You can use them for IPC between different components within your app by placing them in an app group container. Otherwise they are blocked by the sandbox". Temporary file exceptions "don't work for Unix domain sockets".
  - Quinn, F 133543 (2020), https://developer.apple.com/forums/thread/133543: the listener binds in the container, "The client can do the same thing to connect."
  - `com.apple.security.network.client` is **not** mentioned as required for AF_UNIX in any Apple source found. Docs are silent. Adding it is harmless.
  - **Path length:** sun_path is 104 bytes on Darwin, and `~/Library/Group Containers/<group-id>/…` is long. Use a short group ID and socket name. **High.**
- Alternative: a launchd agent with a MachServices name prefixed by the App Group ID. Sandboxed code may look it up through the "App Group Mach service name exception" (Quinn, F 703702, https://developer.apple.com/forums/thread/703702).
  - A Service Management *login item* "can only run a single XPC listener and its name must match the name of the login item". **Med/High.**
- Depending on another long-running process: **no Apple guidance found**.
  - Process lifecycle (F 756084, Apple engineer, May 2024), https://developer.apple.com/forums/thread/756084: "As of macOS 14.4, the system will create one extension process per domain. Prior to macOS 14.4, the system would create a single extension process for all domains" and "the system will terminate extensions which have no outstanding completion handlers". The extension must therefore be stateless, or keep its state persistently. **Med.**

## 11. App Group identifiers on macOS 15+

- Two styles (D, App Groups Entitlement): `group.<group name>` (registered on the developer site) and, in macOS, `<team identifier>.<group name>` ("You don't need to register app groups that use this format").
- Quinn, "App Groups: macOS vs iOS: Working Towards Harmony", https://developer.apple.com/forums/thread/721701 (revised through 2025-08-12). In macOS 15 app group container protection, access without a prompt requires at least one of:
  - Mac App Store distribution.
  - TestFlight (15.1+).
  - "app group ID starts with your app's Team ID".
  - The claim is "authorised by [an] embedded provisioning profile".
  - Otherwise the user is prompted ("would like to access data from other apps"), once per session.
- Since Feb 2025, Mac provisioning profiles can authorise iOS-style `group.` IDs for all product types, and Xcode 16.3+ encourages them.
- Without profile authorisation, macOS clears the "entitlements validated" flag, which breaks the data-protection keychain and container protection.
- **For Developer ID:** the safest naming is `<TEAMID>.<name>` (no prompt, no profile needed). Use `group.<name>` only with a provisioning profile embedded in *every* binary claiming it, including the appex and the daemon if it claims the group. Keep the ID short because of the socket path limit. **Med/High.**
- `NSExtensionFileProviderDocumentGroup` must carry `$(TeamIdentifierPrefix)` (F 702971). **Med.**

## 12. Extension lifecycle and concurrency

- Concurrency (H, NSFileProviderReplicatedExtension):
  > "A replicated extension class must be prepared to handle multiple concurrent calls … The system has limits to the number of concurrent operations."
  - Categories:
    - Working set: at most 1 enumeration at a time.
    - Downloads: `NSExtensionFileProviderDownloadPipelineDepth`, 1–128, honoured from macOS 11.0.
    - Uploads: `NSExtensionFileProviderUploadPipelineDepth`, from macOS 12.0.
    - Metadata-only uploads: `NSExtensionFileProviderMetadataOnlyUploadPipelineDepth`, **macOS 15.0**. **High.**
- Ordering guarantees:
  - "The system guarantees that the creation is called after the creation of the parent completed."
  - For reparenting, the new parent is created first.
  - Local changes never create cycles. Cycles from remote races must be broken by the provider. **High.**
- Cancellation: every call says "If the NSProgress returned by this method is cancelled, the extension should call the completion handler with (… NSUserCancelledError) in the NSProgress cancellation handler" and "The extension is then expected to quickly call the completion handler."
  - No numeric deadline is given for macOS. Timeouts are enforced "on iOS only" (F 756084).
  - item(for:): "not expected to take more than a few seconds".
  - `enumerator(for:)`: "expected to complete quickly … The enumeration logic should happen when the system calls [enumerateItems/enumerateChanges]". **High.**
- Blocking calls: **docs silent**. The API is async with completion handlers, so do not block the calling queue. `NSFileProviderDomainState` properties are read "on the same dispatch queue the completion handler was called on". **High** (text).
- `invalidate()`: "Called before the instance is discarded. … should make sure that all references to the instance are released so that the instance can be deallocated."
  - Several instances may live in one process. Since macOS 14.4 there is one process per domain.
  - Per DTS F 827065, it is also called when the extension is disabled in System Settings. **High/Med.**
- `NSFileProviderEnumerator.invalidate` exists too, so stop live work there. **High.**

## 13. Login items and launch agents

- `SMAppService` (**macOS 13.0**). D https://developer.apple.com/documentation/servicemanagement/smappservice:
  > "For SMAppServices initialized as LaunchAgents, the register() and unregister() methods provide a replacement for installing property lists in ~/Library/LaunchAgents or /Library/LaunchAgents."
- `agent(plistName:)`: "The property list name must correspond to a property list in the calling app's `Contents/Library/LaunchAgents` directory." Use `BundleProgram` (bundle-relative), not `Program` (D "Updating helper executables from earlier versions of macOS"). Agents are per user only; there is no all-users agent (Quinn, F 745720).
- `mainApp`: registers the app itself as a login item (the sandboxed relay app). `agent`: registers a launchd agent (the unsandboxed daemon), getting KeepAlive and MachServices semantics.
- `.notFound`: Quinn, F 719862 (Nov 2022), https://developer.apple.com/forums/thread/719862: "The `.notFound` status means that the system has never seen your service … If you register and then unregister the service, the status goes to the more expected `.notRegistered`."
  - Community reports: a stale Background Task Management DB fixed by `sudo sfltool resetbtm` + reboot (not shippable). Helper binaries must be in a sanctioned location (F 768592 notes `Contents/MacOS`). Unregister followed by register needed a delay (F 768592). **Med/Low.**
- Legacy plists in `~/Library/LaunchAgents`: still supported, and **not** called deprecated.
  - D: "Apps that don't use the new bundle structure can determine whether their app's login items are in a disabled state by checking statusForLegacyPlist(at:)". "If an app installs a legacy property list, the property list needs to include the `AssociatedBundleIdentifiers` key", and the executable's Team ID must match the app's.
  - "In apps that target macOS 13 and later, your app needs to only use the property list locations outlined above". The bundle structure is Apple's stated preference.
  - Every agent appears in System Settings › Login Items with a user toggle, and BTM posts a "Background Items Added" notification (D on Login Items panel). **High.**

## 14. Custom actions, userInfo, decorations

- `NSFileProviderCustomAction.performActionWithIdentifier:onItemsWithIdentifiers:` (macOS 11). It works in replicated extensions (the FruitBasket sample uses it).
  - Info.plist `NSExtension › NSExtensionFileProviderActions` takes an array of dicts with `NSExtensionFileProviderActionIdentifier`, `NSExtensionFileProviderActionName` (localisable) and `NSExtensionFileProviderActionActivationRule` (NSPredicate string).
  - D: "Your action must have a predicate or the system won't display it … To always show an action, use TRUEPREDICATE."
  - The predicate is evaluated against `{fileproviderItems: [items]}`, e.g. `SUBQUERY(fileproviderItems, $i, $i.userInfo."com.example.pinned" == YES).@count > 0`.
  - "You can use predicates to test the value of any of the NSFileProviderItemProtocol object's properties." The listed subset for interactions includes `filename`, `contentType`, `capabilities`, `isUploaded`, `isDownloaded`, `userInfo`, `inheritedUserInfo`, `resolvedUserInfo`, `isRecursivelyDownloaded` and more (H, NSFileProviderItem.h, userInfo comment).
  - `domainUserInfo` comes from `NSFileProviderDomainState.userInfo` (macOS 11.3).
  - D https://developer.apple.com/documentation/fileproviderui/adding-actions-to-the-context-menu. **High.**
- `NSFileProviderItem.userInfo`: values must be String, Number, Bool or Date. Keys ending in `.inherited` propagate to descendants via `inheritedUserInfo`. **High.**
- Decorations: `NSFileProviderItemDecorating.decorations` (macOS 11).
  - Declared in `NSExtension › NSFileProviderDecorations` with Identifier, BadgeImageType (a UTI conforming to `com.apple.icon-decoration.badge`), Label and Category (`Badge` | `Sharing` | `FolderBadge`).
  - "Only the first badge is displayed."
  - A good fit for a "pinned" badge, alongside a `contentPolicy` change. **High.**
- Other Info.plist keys from the headers:
  - `NSExtensionFileProviderAllowsContextualMenuDownloadEntry` = NO hides the system "Download Now" entry.
  - `NSExtensionFileProviderAllowsSystemDeleteAlerts`.
  - `NSFileProviderUserInteractions` (alerts on Move/Trash/Delete…). **High.**

## 15. Materialized-set and pending-set enumerators

- Materialized set: `-[NSFileProviderManager enumeratorForMaterializedItems]` (macOS 11). Roles are reversed: the extension enumerates after `materializedItemsDidChangeWithCompletionHandler:` or the `NSFileProviderMaterializedSetDidChange` notification.
  - "Materialized items are items that have synced to disk and are not dataless … all their children are represented on disk."
  - The purpose is to filter which remote changes go into the working set: "check whether its parentItemIdentifier is in the materialized set … In the case when an item is reparented, the test should be that either the new or the old parentItemIdentifier is in the materialized set."
  - Advice: "use it to set a flag and perform any resulting work as a timed task". **High.**
- Pending set: `enumeratorForPendingItems` (macOS 11.3), `pendingItemsDidChangeWithCompletionHandler:`, `NSFileProviderPendingSetDidChange`.
  > "lists all the items for which a change has been observed either on the disk or in the working set more than one second ago and that change hasn't been applied on the other side yet … an error occurred, in which case the error will be set on the item as `downloadError` … or `uploadError`".
  - Its size is capped (`maximumSizeReached`, macOS 13). It excludes initial uploads of new items.
  - "implementeers should not use the pending set to detect when a change happens." It is meant for an "in progress" UI and activity detection. **High.**
- Both notifications are posted only after `getDomainsWithCompletionHandler:` has been called. **High.**

## 16. stillPendingFields

- H createItem and modifyItem: "If the provider is not able to apply all the fields at once, it should return a set of stillPendingFields in its completion handler. In that case, the system will attempt to modify the item later by calling modifyItem with those fields."
- Unsupported fields (H modifyItem, macOS 12.0+):
  > "Starting in macOS 12.0, if the set of stillPendingFields returned by the provider is identical to the set of fields passed to modifyItem, then the system will consider that these fields are not supported by the provider. The system will not send these fields to the provider again, until the item is modified."
  - This is the only documented "unsupported" signal, and it holds only when the returned set equals the whole passed set. If you return a subset, expect a retry. The docs do not say how often.
- There is **no** declarative list of supported fields. The only related knob is `NSExtensionFileProviderAdditionalSyncableExtendedAttributes`, which adds xattrs.
- Keeping a field local only: either accept it and echo the value back in the returned item (so the disk keeps it, i.e. pretend it is stored), or return it as pending with the "identical set" rule.
  - Never return a different value for a field you did not store: anything not pending and differing from the template "will be propagated to the disk", which would wipe the user's tag or xattr. **High.**
- Field list (`NSFileProviderItemFields`): Contents, Filename, ParentItemIdentifier, LastUsedDate, TagData, FavoriteRank, CreationDate, ContentModificationDate, FileSystemFlags, ExtendedAttributes, and TypeAndCreator (macOS 12).
  - xattrs are capped "to about 32KiB total". `tagData` may be the raw `_kMDItemUserTags` xattr (macOS 12+). **High.**

## 17. Identifier stability

- Identifiers must not contain sensitive information, because they are logged (H).
- createItem: the template's identifier is a system placeholder that is "guaranteed to stay the same for a given item in case the creation is replayed after a crash. That itemIdentifier is not intended to be the identifier assigned to the item by the provider."
  - Returning an existing identifier: "the item that used that identifier will be removed from disk, replaced by the createdItem. If the item is a directory, the two directories will be merged and the items from the existing one will be modified with the NSFileProviderModifyItemMayAlreadyExist option set." **High.**
- modifyItem returning a different identifier is documented **only as a merge**:
  > "The provider can chose to merge two existing items when receiving modifyItem. In that case, the item returned should carry the itemIdentifier of the item with which the item will be merged and well as the resulting state of that item. The system will then keep one of the items (the one whose itemIdentifier was returned) and remove the other one from disk. In case of directories, the content of the two directories is merged and sub-items will be modified with the NSFileProviderModifyItemMayAlreadyExist flag set."
  - Re-identifying on rename (path-derived identifiers) is therefore not supported as a plain rename. It is interpreted as a merge into another item, and the old one is removed from disk.
  - F 713615 asks exactly this, and **no Apple answer** exists there.
  - Identifiers must be stable for an item's lifetime and independent of name and parent. **High** (text), **Med** (conclusion).
- Remote renames and moves: report them as an update of the same identifier with the new `filename` / `parentItemIdentifier` via `didUpdateItems`. That is the model implied by the "Items in this set should have their parentItemIdentifier set to the identifier of their parent directory" rule and by reparent handling.
  - Delete + create would turn a move into a re-download and lose local state. **Med.**
- Losing identifier stability → `reimportItemsBelowItemWithIdentifier:` (Q9). **High.**

## 18. currentSyncAnchor ordering, pageExpired

- The anchor is requested **before** page 1 (H sequence, quoted in Q2).
- F 831362 (Apple engineer, Jun 2026):
  > "There is no atomicity guarantee and the framework doesn't provide one. … The safety invariant is one-directional: the anchor you return must be **at or before** the state delivered in the subsequent page enumeration. Then any change that landed after A will be picked up by the change enumeration that uses A as its starting point — even if that change also affected the page enumeration (you'll just re-deliver it, which is harmless). You should not return an anchor newer than your page snapshot or you would silently skip changes that happened in between."
  - A global backend version is fine. **Med/High.**
- `pageExpired` == `syncAnchorExpired` (-1002). Error text: "the system must re-sync from scratch". **Docs silent** on whether this means re-requesting the anchor and restarting at the initial page. The prudent assumption is a full restart. **Med.**

## 19. temporaryDirectoryURL

- H: "A temporary directory suitable to store files that will be exchanged with the system. The returned URL is guaranteed to be on the same volume as the user visible URL … The provider can also use that directory as a target for moves and clones of content URL passed to createItemBasedOnTemplate or modifyItem."
  - "If the system cannot find a suitable directory, this calls will fail. This could happen e.g. if the domain does not exist or is in instance of initialization." It does not fail from an extension with an active instance, except for disconnected or first-time external domains.
  - It is an instance method on the per-domain manager, so it is per domain. Since macOS 11 / iOS 16. **High.**
- Exact path: **docs silent**, and no reliable public statement was found.
- Cleanup: **docs silent**. The only cleanup statement is for fetchContents files left after a crash: "The extension is then responsible for deleting that file." The provider should sweep its own leftovers at instance start. **High** (for that sentence).
- The unsandboxed daemon does not get this URL from any API. The extension must pass it over the socket. Alternatively the daemon writes into the App Group container, which is valid if it is on the same volume, and the extension clones from there. **Low** (design inference).

## 20. evictItem / requestDownload on directories

- evict on a directory: recursive (Q8). It stops at the first non-evictable child with `nonEvictableChildren`, and partial state is possible. macOS 11.0. **High.**
- requestDownload on a directory: not recursive. A dataless directory is enumerated one level only. Range: `NSMakeRange(NSNotFound, 0)` means full, otherwise `fetchPartialContents` is used. macOS 13.0.
  - The completion fires on acknowledgement, not on download. "requestDownload enqueues the item for downloading at a later time, dependent on device conditions" (F 762894). **High.**
- Recursive keep-downloaded: set the folder's `contentPolicy` to `downloadEagerlyAndKeepDownloaded`. Inherited children follow. **High** (H text on inheritance).

## 21. Item properties for a replicated extension

- Required: `itemIdentifier`, `parentItemIdentifier`, `filename` (non-empty, the root included).
  - "On macOS, items must implement contentType."
  - Must handle `UTType.symbolicLink`, `.folder`, `.package` and `.aliasFile` in templates.
  - "Changing the contentType for a given item that would result in a transition to/from a folder or to/from a symlink is not supported." **High.**
- `itemVersion` (macOS 11): effectively required.
- `documentSize`: must match the real byte size. F 734032 (Jul–Aug 2023), https://developer.apple.com/forums/thread/734032: a mismatched size caused an immediate `modifyItem` re-upload after every fetch. **Med.**
- `capabilities`: UI gating only, since "direct file system changes (e.g. from Terminal) can still result in changes that must be handled". They are not inherited. **High.**
- `fileSystemFlags` (userExecutable/Readable/Writable, hidden, pathExtensionHidden): honoured for directories from macOS 11.3.
- `typeAndCreator`: macOS 12. `extendedAttributes`: about 32 KiB of syncable xattrs.
- `isUploaded` / `isUploading` / `uploadingError`: used. `uploaded` gates eviction. `uploadingError` typically carries insufficientQuota or serverUnreachable.
- `isDownloaded` / `isDownloading`: "When using NSFileProviderReplicatedExtension, downloaded and downloading are ignored, as they can be inferred from the result of calls to fetchContentsForItemWithIdentifier." `downloadingError` is not stated as ignored. **High.**
- `childItemCount`, `creationDate`, `contentModificationDate`, `lastUsedDate`, `tagData`, `favoriteRank`, `trashed`, `shared*`, owner names: optional.
  - `favoriteRank` and `trashed` are marked V2 (iOS only): **unavailable on macOS**. Trash is expressed by `parentItemIdentifier == .trashContainer`: "When an item is trashed, its `parentItemIdentifier` becomes `NSFileProviderTrashContainerItemIdentifier`." **High.**
- `contentPolicy`: per item (Q8). `userInfo`: for predicates (Q14). `symlinkTargetPath`: for symlinks.
- `versionIdentifier` / `typeIdentifier`: unavailable on macOS. **High.**

## 22. Re-added domain, reimport

- After `reimportItemsBelowItemWithIdentifier:`, the system scans the on-disk data and calls **createItem** with `mayAlreadyExist` for each item, not modifyItem. Then it calls `importDidFinishWithCompletionHandler:`. "the system will reimport at least the requested sub-tree, but may import more." **High.**
- After `importDomain:fromDirectoryAtURL:`, likewise createItem with `mayAlreadyExist` for every item. **High.**
- `mayAlreadyExist` is also used for children of merged directories, and for "items found on disk after the synchronisation state was lost, for example following the restoration of a backup, or the migration to a new device" (H). `addDomain` is also named as triggering `importDidFinish`. **High.**
- A fresh `addDomain` after removal with `preserveDirtyUserData`: **docs silent** on any automatic re-ingest of the preserved location.
  - The completion's URL is just where the data was left. `addDomain` fails with NSFileWriteFileExistsError if the replica location already exists.
  - To re-ingest, the app must use `importDomain:fromDirectoryAtURL:` with that directory, or copy files in after `addDomain`. Copying in arrives as plain createItem without `mayAlreadyExist`. **Med** (inference).
- Matching during import:
  - With content: compare hash or size and mtime to the server.
  - Without content (dataless): "return a nil item if you are not able to match". **Docs ambiguous:** whether a nil item for a dataless reimported file deletes it. The generic rule is that a nil createdItem deletes the source from disk.

---

## Surprises / API pitfalls

1. **Spurious `noSuchItem` deletes user files.** Returned from `item(for:)`, `fetchContents`, `modifyItem` or `enumerator(for:)`, it makes the system delete the on-disk item, re-creating it only if it has local edits. Never return it when the daemon is merely unreachable or not yet loaded. Use `serverUnreachable` or a transient error instead.
2. **A nil createdItem with no error deletes the source from disk**, recursively for a directory. Use `excludedFromSync` (macOS 13+) to keep it local.
3. **`cannotSynchronize` on create or modify is near-permanent.** No retry until an OS or extension update, a local edit, or `signalErrorResolved(.cannotSynchronize)`. Never use it for transient faults.
4. **Error domain discipline.** Only `NSCocoaErrorDomain` and `NSFileProviderErrorDomain` are allowed. Wrap anything else as `NSXPCConnectionReplyInvalid` with `NSUnderlyingErrorKey`. Errors carried over the socket must be mapped.
5. **Resolvable errors may not latch the domain.** In practice (F 803669) operations are retried with backoff per item. Recovery still requires `signalErrorResolved` for each code, plus a working-set signal.
6. **`signalEnumerator` for any container other than `.workingSet` is silently ignored** in replicated mode. Apple's own article still says otherwise.
7. **Folders are enumerated once.** `enumerateChanges` is working-set only, and folder anchors are unused. Every remote change to a materialized-parent item must go through the working set, or the replica goes stale forever ("there is no alternative cache invalidation mechanism").
8. **Anchor ordering.** The anchor must be at or before the page snapshot. A newer anchor silently loses changes. Over-delivery is harmless.
9. **Working-set anchor expiry is very expensive.** It scans all known items and may re-evaluate every folder. Expire only on genuine history loss, and keep anchors stable across daemon restarts.
10. **500-byte anchors and pages.** An oversized anchor equals `syncAnchorExpired`, and an oversized page aborts the enumeration.
11. **128-byte version components.** Full hashes fit, but a JSON blob might not.
12. **`documentSize` must equal the bytes delivered.** A mismatch triggers a phantom re-upload loop (F 734032).
13. **`fetchContents` file ownership.** The system clones then **unlinks** the returned file, and may not unlink it after a crash. Never return a daemon cache file; return a `clonefile` copy on the same volume. Sweep leftovers on start.
14. **create/modify content URL dies at completion.** Clone it before calling the handler if the upload continues afterwards.
15. **Completing before the upload ends is allowed in the header** (set `isUploaded = NO`, report completion through the working set). It is discouraged by an Apple engineer (2026), impossible on iOS, and bypasses the upload pipeline depth.
16. **Fields you cannot store.** Returning them in the completion item with different values overwrites the disk. Either echo the template values or return them in `stillPendingFields`; an identical set means "unsupported" (macOS 12+).
17. **Identifiers must be stable and independent of path.** Returning a different identifier from `modifyItem` means *merge*, and the system removes the other item from disk.
18. **Capabilities are UI-only.** Terminal edits still arrive and must be handled, including renames, deletes and writes on items flagged read-only.
19. **Concurrency.** Calls arrive concurrently, with a single working-set consumer. Since macOS 14.4 there is one extension process per domain. The system kills idle extensions, so keep no essential state in memory.
20. **Cancellation.** The completion handler must be called promptly from the progress cancellation handler with `NSUserCancelledError`, and exactly once.
21. **Eviction.** It fails for unsynced edits (`unsyncedEdits`; the web docs say `NSFileWriteNoPermissionError`), for pinned items (`nonEvictable`), for open files (EBUSY) and for hard links (EMLINK). Directory eviction can stop half way.
22. **`requestDownload` is a hint.** It completes on enqueue and is never recursive. Pinning is `contentPolicy = downloadEagerlyAndKeepDownloaded` (macOS 13+), and is inherited.
23. **`allowsEvicting` is deprecated (macOS 13).** On 11–12, absence meant "never evict"; on 13+ the content policy governs. Do not depend on the flag.
24. **`reimportItems(below: .root)`** can kill the extension process before its completion handler runs, and rebuilds the backing store (`backingStoreIdentity` changes). The system can also start a reimport on its own.
25. **`mayAlreadyExist` imports arrive as createItem**, possibly dataless (`url == nil`). Matching must be cheap first, because every on-disk item comes through.
26. **Domain deletion conflicts.** A remote delete of a locally edited item comes back as createItem with `deletionConflicted` and the old identifier. On a dataless item it is deleted immediately.
27. **Trash.** `supportsSyncingTrash` defaults to YES. A trashed item's parent becomes `.trashContainer`, and the enumerator for the trash must work or fail with `NSFeatureUnsupportedError`. `isTrashed` is iOS-only.
28. **Collision checks are case-insensitive.** Use `fileProviderErrorForCollisionWithItem:`; the system bounces one item and retries.
29. **Unix socket path length.** sun_path is 104 bytes on Darwin, and the group container path is long. Keep the group ID and socket name short.
30. **App Group naming on Developer ID.** Use a `TEAMID.` prefix to avoid the macOS 15 "access data from other apps" prompt, unless every binary carries a profile authorising a `group.` ID. `NSExtensionFileProviderDocumentGroup` needs `$(TeamIdentifierPrefix)`.
31. **`providerNotFound` (-2001) at addDomain** is usually signing or packaging: an unsandboxed appex, `codesign --deep`, a wrong profile, or an unregistered app bundle.
32. **`SMAppService` `.notFound`** means "never seen", not broken. BTM state can go stale (`sfltool resetbtm` is dev-only). Legacy `~/Library/LaunchAgents` plists still work but need `AssociatedBundleIdentifiers` with a matching Team ID, and they appear as Background Items.
33. **macOS 26-only APIs:** `failOnConflict`, `localVersionConflictingWithServer`, `isImmediateUploadRequestByPresentingApplication`, `NSFileProviderSearching`, `supportsStringSearchRequest`. Guard them with availability checks for a macOS 13 deployment target. External volumes and known folders need 15.0, the metadata-only pipeline depth key needs 15.0, and diagnostics need 15.4.
34. **Non-materializing processes.** The user default `NSFileProviderExtensionNonMaterializingProcessNames` lets the provider stop named executables (e.g. an indexer, backup tool or the daemon itself) from triggering downloads. This is useful if the daemon ever touches the replica.

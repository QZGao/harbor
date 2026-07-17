# Magnet Metadata Continuation Design

## Problem

When Harbor starts a magnet URI, aria2 first retrieves the torrent metadata. With
`bt-save-metadata` enabled, aria2 can report that metadata result as `complete`
while the actual torrent payload has not completed. Harbor currently treats any
`complete` status as final, marks the download 100%, clears its backend GID, and
removes the aria2 result. This leaves the real payload untracked and incomplete.

## Goals

- Keep a magnet download active after metadata retrieval until its payload is
  complete.
- Preserve the existing `DownloadItem` and user-visible history.
- Follow aria2’s generated payload GID without submitting a duplicate torrent.
- Avoid completion notifications and cleanup until the payload completes.
- Add regression coverage for the metadata-to-payload transition.

## Native aria2 lifecycle

aria2 models a followed download as a GID lineage. The magnet metadata is the
parent download. When `follow-torrent` creates the real torrent payload, the
parent status exposes the generated payload GID in `followedBy`, and the child
status exposes the parent GID in `following`. aria2 also saves the metadata
parent GID in its session file, so Harbor needs to retain that stable root while
directing live transfer operations to the current child.

## Recommended approach

Harbor will request `followedBy` and `following` in every torrent status query.
When a magnet metadata snapshot completes with a child GID, Harbor will treat it
as an intermediate transition and begin refreshing the child instead of marking
the item complete. The item remains downloading, retains its original magnet
source and stable root GID, and receives its real payload paths and byte counts
from the child status.

Harbor will also enable aria2’s `bt-load-saved-metadata` option so a restored
magnet can reuse the metadata file already saved by `bt-save-metadata` instead
of retrieving the same metadata from peers again.

Harbor will keep the stable metadata root GID as persisted state and maintain
the current child GID as runtime state. Pause, resume, limits, cancellation, and
data removal target the current child. Session reconciliation will recognize
children whose `following` lineage reaches a persisted root and will not remove
them as orphans. When the real payload completes or the user removes the item,
Harbor will clean up the full GID lineage.

If a completed magnet metadata result has no generated child yet, Harbor will
keep it in a waiting state and recheck rather than claiming success. A genuine
aria2 error remains retryable through Harbor’s existing torrent error path.

## Alternatives considered

1. Manually submit the saved metadata `.torrent` file as a second download.
   This duplicates aria2’s native follow behavior and makes session restoration
   harder because RPC-uploaded torrent metadata has different persistence rules.
2. Disable metadata saving and rely on the current status handling. This is
   smaller but still does not distinguish metadata completion from payload
   completion.
3. Mark metadata completion as paused and require manual retry. This avoids a
   false success but creates a poor user experience and leaves the workflow
   incomplete.

## Testing

- Unit-test decoding and recognition of `followedBy` and `following` lineage.
- Unit-test that metadata completion follows its child instead of setting
  `finishedAt`, clearing the item, or emitting completion state.
- Unit-test that restored child GIDs are retained when their lineage reaches a
  persisted magnet root.
- Unit-test pause, cancellation, and cleanup target the active child GID.
- Test the normal torrent-file completion path remains unchanged.
- Run the Harbor XCTest suite and the project build verification script.

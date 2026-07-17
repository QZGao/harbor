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
- Reuse the metadata file aria2 saved in the destination folder.
- Avoid completion notifications and cleanup until the payload completes.
- Add regression coverage for the metadata-to-payload transition.

## Recommended approach

When the refresh loop sees a `complete` snapshot for a magnet whose reported
payload is the `[METADATA]...` result, Harbor will treat it as an intermediate
state. It will locate the saved metadata torrent using the magnet info hash,
submit that `.torrent` file to aria2 through a dedicated torrent-file add path,
replace the item’s backend identifier, and continue refreshing the same item.
The old metadata result will be removed only after the replacement GID has been
accepted.

The item remains in a preparing/downloading state, retains the original magnet
source, and receives the real payload paths and byte counts from the replacement
GID. If the metadata file is missing or the replacement add fails, Harbor will
leave the metadata file in place and surface a retryable torrent error rather
than claiming success.

## Alternatives considered

1. Disable metadata saving and rely only on aria2’s follow-torrent behavior.
   This is smaller but weakens recovery and does not protect Harbor from another
   intermediate completion result.
2. Mark metadata completion as paused and require manual retry. This avoids a
   false success but creates a poor user experience and leaves the workflow
   incomplete.

## Testing

- Unit-test recognition of metadata-only completion snapshots.
- Unit-test that metadata completion does not set `finishedAt`, clear the item,
  or emit completion state.
- Test the normal torrent-file completion path remains unchanged.
- Run the Harbor XCTest suite and the project build verification script.

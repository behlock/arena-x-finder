# Complete Finder listings: investigation, 27 October 2026

## Implementation follow-up

The 100-item page size is now installed. Verified in the real Hardware Finder
folder: 67 items, no continuation folder, one metadata-page request, and no
original-file downloads during refresh. Existing cached page folders migrate
without changing surviving block identifiers. Refresh now reconciles previously
opened pages through macOS's working-set change feed. Channels above 100 items
still use explicit continuation folders, each containing at most 100 remote
items. The investigation below records the findings before this implementation.

## Finding

Hardware currently contains 67 items, as shown by the signed-in Are.na channel
page and its official export. The channel-contents endpoint supports `per=100`.
This channel can therefore fit in one ordinary metadata response: the app's
current 24-item page size is the immediate cause of its extra folders.

Increasing the page size is a proposed implementation change, not an installed
change from this investigation. A live authenticated `per=100` request has not
been run. Larger channels would still need a deliberate pagination design.

## Official export: actually tested

Opened Hardware in the user's existing signed-in Safari session and used
More → Download. The current dialog offered a ZIP and a "Blocks per file"
setting (default 1000); it did not offer an HTML-only or metadata-only choice.
Although Are.na's About page lists HTML, PDF, and ZIP exports, only the ZIP
workflow was verified here.

The downloaded ZIP is 62,734,055 bytes. It contains a CSV manifest and 67 files:
13 JPEG, 19 PNG, 1 WebP, 1 GIF, 31 web shortcuts, and 2 text files. These include
nested-channel shortcuts; nested channels were not recursively exported.

The CSV has 67 rows, 67 distinct IDs, and these columns:
`ID`, `Filename`, `Title`, `Description`, `Created At`, `Updated At`, `Source`.
Every Filename exactly matches an archive member. All 48 currently cached
provider block/channel records had matching IDs in this manifest.

The Source column is sometimes empty and otherwise points to source websites
or images. It is not a complete set of original-file download URLs. The CSV
also lacks an explicit block/channel type, connection ID, and channel-membership
change cursor. A metadata-only importer would need to resolve missing details
on demand, preserve type distinctions, and verify current access.

Three of the 31 `.webloc` files fail strict plist parsing. An importer should
validate and safely reconstruct shortcuts rather than trust exported XML or
extract archive paths unchecked. The inspection script reports aggregate
structure without printing private content.

This export can seed a complete local snapshot. It is not an efficient way to
create cloud-only placeholders: the official workflow already downloaded the
media. The ZIP remains in Downloads; private export contents were not copied
into this repository or imported into the active Finder domain.

## Updates after an export

The current published v3 OpenAPI specification has no export operation, webhook,
or complete per-channel delta feed with removal events. The contents endpoint
offers page/per, sorting, and contributor filtering, not a change cursor.

Premium search supports `channel_id` and `after` for updated results. That may
help discover edits, but the documentation does not establish that it captures
all membership additions, disconnections, deletions, or reordering. It cannot
be treated as a complete synchronization protocol without further evidence.
Counts alone also cannot reveal an addition and removal that cancel out.

Therefore export + recent-page refresh is a partial cache, not a trustworthy
complete live mirror. Exact refresh of a larger channel still needs a supported
reconciliation method or another explicitly requested official snapshot.

## Finder and published guidance

Apple's local SDK documents that a replicated folder enumeration follows
continuation pages until the provider returns nil. Lazy namespace policy delays
enumerating a folder until access; it does not provide a scroll-triggered page
callback. Switching to it would not solve this issue.

Are.na's published guidance says to fetch subsequent pages on demand and avoid
looping over a channel's entire contents. No published exception for a complete
listing of a user-selected channel was found. The official export is a separate,
explicit user workflow; its availability is not permission for an API crawler.

The unresolved question for Are.na is whether a native File Provider may cache
the complete metadata listing of an explicitly selected channel, with lazy file
downloads and conditional, rate-limited refresh, and what supported method can
report membership removals. No message has been sent to Are.na.

## Recommendation

1. Use a single request of up to 100 items for explicitly opened channels. This
   should remove pagination entirely for Hardware's current 67 items.
2. Keep exports as an optional snapshot-import feature, not the foundation of
   live synchronization. A production importer is not implemented here.
3. For larger channels, retain explicit loading until Are.na clarifies full
   metadata enumeration. If needed, append user-requested batches into one
   folder with a visible companion control instead of nesting page folders.

## Sources and reproduction

- [Channel contents and maximum page size](https://www.are.na/developers/explore/channel/contents)
- [API acceptable use, pagination, and caching](https://www.are.na/developers/explore)
- [Official export instructions](https://help.are.na/docs/getting-started/channels/settings-and-export)
- [Advertised export formats](https://www.are.na/about)
- [Premium search and after filter](https://www.are.na/developers/explore/search/search)
- [Current OpenAPI specification](https://api.are.na/v3/openapi)
- Local Apple SDK: `FileProvider.framework/Headers/NSFileProviderReplicatedExtension.h`,
  `enumeratorForContainerItemIdentifier:request:error:` documentation.

```sh
python3 scripts/inspect-arena-export.py "$HOME/Downloads/hardware-xuas3inmx_m.zip"
```

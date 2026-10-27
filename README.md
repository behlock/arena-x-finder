# Are.na x Finder

A native macOS app that brings selected Are.na channels into Finder, with on-demand downloads and drag-in uploads.

Browse your channels under Finder’s **Locations**, preview files with Quick Look, and drop files into a channel to upload. Inspired by [Figma x Finder](https://github.com/behlock/figma-x-finder), with direct uploads through Are.na’s v3 API.

## Requirements

- macOS 13 or later.
- Xcode or the Xcode Command Line Tools, including Swift 5.9 or later.
- An Are.na account and a personal access token with **write** access.
- An Apple Development signing identity installed in Keychain. The build picks the first available Apple Development identity; set `ARENA_SIGNING_IDENTITY` to choose another. The Finder extension cannot use the original app’s ad hoc signature.
- The sibling `../webloc-thumbnail-generator` project when building from source. Its `ThumbnailCapture` and `ThumbnailCore` libraries are compiled into the app; installed copies do not need the source folder at runtime.

## Install

From the project directory:

```sh
bash scripts/install.sh
open "$HOME/Applications/Are.na x Finder.app"
```

The installer builds and signs the app and its sandboxed File Provider extension, installs them in `~/Applications`, and registers the extension. You can pass another application directory as the first argument to the installer.

## Connect your account

1. Open [Are.na’s personal access token settings](https://www.are.na/settings/personal-access-tokens).
2. Create a token with **write** access.
3. Paste it into the app and click **Connect**.

Once connected, the compact panel shows a channel picker and one **Add to Finder** / **Open in Finder** action. **Add by URL…** sits underneath. Account and recovery controls live in the macOS **Are.na x Finder** menu.

The app validates the token against your profile and saves it in macOS Keychain. Tokens are never stored in the repository or the queue’s JSON file. Your account’s channels load one page at a time as you scroll to the end of the channel picker. **Add by URL…** adds a specific accessible channel directly to Finder, including private and shared channels.

If channel discovery is unavailable for your account, you can still add a channel by URL after connecting. A successful connection validates your identity; each Finder folder reflects its own channel’s upload permissions.

## Channels in Finder

1. Connect your account in the app.
2. Choose a channel and click **Add to Finder**. Once added, the button becomes **Open in Finder**.
3. Alternatively, use **Add by URL…** to paste a channel link and add its folder in one step.
4. Click **Enable** in Finder if macOS asks you to enable the provider.

Channels you explicitly add appear at the top level under **Are.na x Finder** in Finder’s Locations. Connected channels appear as folders inside them. This is a native File Provider domain, not a generated local folder mirror.

- **Browse:** images and attachments appear as files; text blocks become Markdown files; links and embeds become `.webloc` shortcuts. Connected channels become folders whose contents load when opened. They retain their own Are.na permissions; write access to a parent does not grant write access to its connected channels.
- **Preview:** thumbnails use small image versions; Quick Look and opening/copying a file fetch its full contents when needed. Downloaded files may be evicted by macOS.
- **Website previews:** `.webloc` items use Are.na's small preview image when available, otherwise the capture and rendering code from Webloc Thumbnails generates a screenshot automatically. A background helper handles loaded channel items, caches successful screenshots for seven days, and backs off failed captures for a day. Sites requiring sign-in or blocking capture may retain a generic icon. The renderer uses an isolated browser session and never receives the Are.na token.
- **Upload:** drop regular files up to **100 MB** into a writable channel folder. Finder manages the local pending copy and invokes the extension. The native import path preserves the original bytes; it does not use the picker’s image resizing.
- **Refresh:** opening a channel or a **More items** folder checks its listing automatically when Finder subscribes to that directory. A 15-second freshness window avoids repeat API requests. Cached items remain available if the request fails. **Are.na x Finder → Refresh** forces a refresh when needed; this prototype does not continuously poll or use server push notifications.
- **Long channels:** each folder shows up to **100 items**, plus a **More items (page N)** folder when another batch exists. Open that folder to fetch the next batch of up to 100. Channels with 100 or fewer items fit in one folder. Finder eagerly requests every native continuation page, so explicit page folders prevent a normal folder visit from fetching the whole channel.
- **Names:** channel and block IDs are appended to names to distinguish duplicate titles. The same channel can appear in multiple branches independently. A connection back to an ancestor stays a `.webloc` shortcut to prevent an endless folder chain.
- **Scope:** remote rename, move, delete, folder creation, and edits to existing files are unavailable. Existing remote files appear read-only. Dropping new files is supported.

The extension remembers created block IDs before completing an import, so a replay from macOS does not create another block. If the result of a creation request is unknown, it stops and reports an error. Use **Review Finder uploads…** to link the block that was created, or explicitly allow a retry after checking the channel. Files still processing on Are.na can be retried without re-uploading.

API metadata/write requests are paced separately from thumbnail/file transfers. Automatic browsing refreshes only the requested folder’s API page. Working-set and thumbnail updates use cached listings; they do not poll every previously visited channel. Failed checks back off for at least 15 seconds, respecting longer API retry intervals. A count-only `request-counts.json` records API pages, thumbnails, file downloads, and uploads for testing. No tokens or filenames are logged there.

The Finder configuration, metadata, thumbnails, and import ledger live in the signed app’s group container under `~/Library/Group Containers/<team>.com.behlock.arena-x-finder/`. Credentials stay in the login Keychain, with an explicit ACL for the signed host app and extension. The Mac-only app group is derived from your signing team during the build.

The installer starts a per-user LaunchAgent, `com.behlock.arena-x-finder.thumbnails`, for the bundled thumbnail helper. It runs without the picker window, renders one page at a time with a 20-second deadline, and checks its shared queue every two seconds when idle. Finder receives preview images through the provider's thumbnail API. The provider updates the shortcut's content version and modification date when a generated image becomes ready so Finder refreshes its cached icon. The helper does not edit files under CloudStorage, and shortcuts can remain undownloaded. To stop automatic screenshot generation:

```sh
launchctl bootout "gui/$(id -u)/com.behlock.arena-x-finder.thumbnails"
```

Remove `~/Library/LaunchAgents/com.behlock.arena-x-finder.thumbnails.plist` as well to keep it disabled after login. Reinstalling the app enables it again. Existing previews and link destinations are preserved.

Are.na’s API guidance prohibits systematic downloading and account-wide crawling. This prototype uses explicitly selected channels and bounded page folders; this is an implementation constraint, not a claim of endorsement or an exception to their usage policy.

## Upload from Finder

Copy/paste or drag regular files into a writable channel folder under **Are.na x Finder**. Finder handles the pending copy and upload; you can close the management window. The app no longer has a send arrow, image-batch controls, or a **Send to Are.na** service.

Finder uploads preserve original file bytes and accept individual files up to 100 MB. Channel permissions and Are.na account storage limits still apply. Use **Are.na x Finder → Refresh** to request updated listings.

## Interrupted uploads

Finder shows upload progress and errors on the affected files. When a creation request has an uncertain result, **Are.na x Finder → Review interrupted uploads…** appears in the app. Check the channel before linking an existing block or allowing a retry; this prevents duplicates after a dropped connection. Recovery is hidden when there is nothing to review.

Existing data from the retired image-batch uploader remains in `~/Library/Application Support/Are.na x Finder/`; the new interface does not submit or delete those historical batches.

## Development

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

The app bundle is written to `build/Are.na x Finder.app`.

- `Sources/ArenaCore`: API client, channel/block models, Keychain vault, image preparation, durable picker queue, uploader.
- `Sources/ArenaProvider`: native File Provider adapter, page/cache model, import recovery, live and local-demo backends.
- `Sources/ArenaFinder`: channel management window, background thumbnail worker, and Keychain integration.
- `Tests`: mocked API upload/recovery tests, queue persistence tests, preview behavior tests.
- `App/Info.plist`: app identity.

For isolated local development, `ARENA_FINDER_DATA_DIR` overrides the queue directory. It does not change the Keychain entry. Avoid running multiple copies against the same data directory.

Automated tests use generated images, mocked HTTP responses, and a local demo backend. They do not upload to an Are.na account.

For a native integration smoke test after installation:

```sh
"$HOME/Applications/Are.na x Finder.app/Contents/MacOS/Are.na x Finder" --finder-smoke
```

The first run may report that sync is disabled. Open the **Are.na Demo** location in Finder, click **Enable**, and run the command again. The test uses macOS file coordination to enumerate a synthetic channel, materialize a file, and submit a new local file through the actual extension. It also checks credential sharing with a temporary, nonsecret Keychain item. No live Are.na content is used.

Remove the demo location afterwards, preserving any unsynced files:

```sh
"$HOME/Applications/Are.na x Finder.app/Contents/MacOS/Are.na x Finder" --finder-remove-demo
```

Validated on the development Mac: native domain registration, private-channel listing, thumbnails, one image opened through Quick Look, local demo import completion, and shared Keychain access. Automatic website previews were also verified visually in Finder: 29 of 31 loaded website shortcuts received screenshots before nested channels became folders; two captures failed and retained generic icons. Captures can show a site's cookie banner, sign-in page, or loading placeholders. The nested-folder upgrade converted 19 connections in Hardware, and opening Hello Robots loaded 100 items plus a continuation folder with one additional metadata request. Automatic refresh was verified by reopening Hardware: one metadata request refreshed that folder without fetching the nested channel, and an immediate second visit made no extra request. A live write into Are.na has not been exercised by these tests.

## Troubleshooting

- **Access denied:** check the token’s write access and the channel’s contributor permissions.
- **Token revoked:** open **Account…** and connect with a new token.
- **Keychain prompt:** allow the signed app to access its saved token when connecting. Reconnect after switching signing identities. The native integration uses the macOS login Keychain ACL API, which is deprecated but works on the tested system; a distributable release should move to a provisioned shared Keychain group.
- **Paste:** the app provides the standard Edit menu and ⌘V in its secure token field.
- **Finder location missing or disabled:** reinstall the signed app, click **Add to Finder**, and enable the provider in Finder if prompted.
- **Only 100 items:** open **More items** for the next batch. After upgrading from the 24-item version, use **Are.na x Finder → Refresh** to update existing listings.
- **Live upload test:** drop a file you intend to add into a channel and check it on Are.na; the local demo only verifies the Finder side of importing.

## API references

- [Authentication and rate limits](https://www.are.na/developers/explore)
- [Channel discovery](https://www.are.na/developers/explore/user/contents)
- [Upload flow](https://www.are.na/developers/resources/sdk)
- [Create a block](https://www.are.na/developers/explore/block/post-block)
- [Current OpenAPI specification](https://api.are.na/v3/openapi)

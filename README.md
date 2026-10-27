# Are.na x Finder

A native macOS app that brings selected Are.na channels into Finder, with on-demand downloads and drag-in uploads.

Browse your channels under Finder’s **Locations**, preview files with Quick Look, and drop files into a channel to upload. The original **Services → Send to Are.na** picker remains available. Inspired by [Figma x Finder](https://github.com/behlock/figma-x-finder), with direct uploads through Are.na’s v3 API.

## Requirements

- macOS 13 or later.
- Xcode or the Xcode Command Line Tools, including Swift 5.9 or later.
- An Are.na account and a personal access token with **write** access.
- An Apple Development signing identity installed in Keychain. The build picks the first available Apple Development identity; set `ARENA_SIGNING_IDENTITY` to choose another. The Finder extension cannot use the original app’s ad hoc signature.

## Install

From the project directory:

```sh
bash scripts/install.sh
open "$HOME/Applications/Are.na x Finder.app"
```

The installer builds and signs the app and its sandboxed File Provider extension, installs them in `~/Applications`, and registers the Finder service and extension. You can pass another application directory as the first argument to the installer.

## Connect your account

1. Open [Are.na’s personal access token settings](https://www.are.na/settings/personal-access-tokens).
2. Create a token with **write** access.
3. Paste it into the app and click **Connect**.

The app validates the token against your profile and saves it in macOS Keychain. Tokens are never stored in the repository or the queue’s JSON file. Your account’s channels load one page at a time; click **Load more** for the next page. **Add channel URL…** lets you add a specific channel, including a shared channel you can contribute to.

If channel discovery is unavailable for your account, you can still add a channel by URL after connecting. A successful connection validates your identity; write access is checked when you send.

## Channels in Finder

1. Connect your account in the app.
2. Choose a channel, or use **Add channel URL…** to add a private/shared channel.
3. Click **Show channel in Finder**.
4. Click **Enable** in Finder if macOS asks you to enable the provider.

Only channels you explicitly add appear under **Are.na x Finder** in Finder’s Locations. This is a native File Provider domain, not a generated local folder mirror.

- **Browse:** images and attachments appear as files; text blocks become Markdown files; links, embeds, and nested channels become `.webloc` shortcuts.
- **Preview:** thumbnails use small image versions; Quick Look and opening/copying a file fetch its full contents when needed. Downloaded files may be evicted by macOS.
- **Upload:** drop regular files up to **100 MB** into a writable channel folder. Finder manages the local pending copy and invokes the extension. The native import path preserves the original bytes; it does not use the picker’s image resizing.
- **Refresh:** use **Refresh Finder** in the app to request fresh listings. This prototype does not continuously poll or use server push notifications.
- **Long channels:** each folder shows up to **100 items**, plus a **More items (page N)** folder when another batch exists. Open that folder to fetch the next batch of up to 100. Channels with 100 or fewer items fit in one folder. Finder eagerly requests every native continuation page, so explicit page folders prevent a normal folder visit from fetching the whole channel.
- **Names:** channel and block IDs are appended to names to distinguish duplicate titles. Nested channel shortcuts avoid recursive channel graphs.
- **Scope:** remote rename, move, delete, folder creation, and edits to existing files are unavailable. Existing remote files appear read-only. Dropping new files is supported.

The extension remembers created block IDs before completing an import, so a replay from macOS does not create another block. If the result of a creation request is unknown, it stops and reports an error. Use **Review Finder uploads…** to link the block that was created, or explicitly allow a retry after checking the channel. Files still processing on Are.na can be retried without re-uploading.

API metadata/write requests are paced separately from thumbnail/file transfers. Existing loaded listings are cached until an explicit refresh. A count-only `request-counts.json` records API pages, thumbnails, file downloads, and uploads for testing. No tokens or filenames are logged there.

The Finder configuration, metadata, thumbnails, and import ledger live in the signed app’s group container under `~/Library/Group Containers/<team>.com.behlock.arena-x-finder/`. Credentials stay in the login Keychain, with an explicit ACL for the signed host app and extension. The Mac-only app group is derived from your signing team during the build.

Are.na’s API guidance prohibits systematic downloading and account-wide crawling. This prototype uses explicitly selected channels and bounded page folders; this is an implementation constraint, not a claim of endorsement or an exception to their usage policy.

## Send images using the picker

1. Select up to **100 images** in Finder.
2. Right-click → **Services → Send to Are.na**.
3. Click a preview to enlarge it, or remove images from the selection.
4. Choose a channel and click the send arrow.

Keep the Mac app running until the upload finishes. Are.na does not need to be open in your browser. The app remembers the last channel you used. To send another selection, invoke the Finder service again.

The initial version supports images readable by macOS Image I/O. JPEG and PNG files within the size limits retain their original bytes. Other formats are converted to PNG; images are limited to 4,096 pixels on the longest edge and 10 MB per prepared image. Transparency is preserved. Animated files use their first frame. Original files are never modified.

## Unfinished uploads

Prepared images and progress are kept in:

```text
~/Library/Application Support/Are.na x Finder/
```

- Reopen the app and click **Resume** to continue a queued batch.
- Successfully created block IDs are saved before checking Are.na’s processing status. Resuming checks the same block instead of creating another.
- If the connection drops while creating a block, **Review upload…** opens the destination channel. Check whether the image exists and choose **Already added** or **Missing — allow retry**. The app does not automatically repeat an ambiguous creation request.
- If Are.na is still processing a block, wait and resume to check it again.
- If a block fails processing, review it in Are.na and discard the local batch before sending a replacement.
- **Discard batch…** removes queued local copies, preserving original files and any blocks already created in Are.na.
- Finish or discard pending batches before changing accounts.

Uploads run sequentially. Rate-limit errors show when to retry; the app does not repeatedly retry rejected writes. Are.na account storage limits and channel permissions still apply.

## Development

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

The app bundle is written to `build/Are.na x Finder.app`.

- `Sources/ArenaCore`: API client, channel/block models, Keychain vault, image preparation, durable picker queue, uploader.
- `Sources/ArenaProvider`: native File Provider adapter, page/cache model, import recovery, live and local-demo backends.
- `Sources/ArenaFinder`: AppKit picker and previews, Finder service, Keychain integration.
- `Tests`: mocked API upload/recovery tests, queue persistence tests, preview behavior tests.
- `App/Info.plist`: app identity and Finder service registration.

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

Validated on the development Mac: native domain registration, private-channel listing, thumbnails, one image opened through Quick Look, local demo import completion, and shared Keychain access. A live write into Are.na has not been exercised by these tests.

## Troubleshooting

- **Finder service missing:** open the app once, then check macOS Services settings for **Send to Are.na**. Re-run the installer if needed.
- **Access denied:** check the token’s write access and the channel’s contributor permissions.
- **Token revoked:** open **Account…** and connect with a new token.
- **Keychain prompt:** allow the signed app to access its saved token when connecting. Reconnect after switching signing identities. The native integration uses the macOS login Keychain ACL API, which is deprecated but works on the tested system; a distributable release should move to a provisioned shared Keychain group.
- **Paste:** the app provides the standard Edit menu and ⌘V in its secure token field.
- **Finder location missing or disabled:** reinstall the signed app, click **Show channel in Finder**, and enable the provider in Finder if prompted.
- **Only 100 items:** open **More items** for the next batch. After upgrading from the 24-item version, use **Refresh Finder** to update existing listings.
- **Live upload test:** drop a file you intend to add into a channel and check it on Are.na; the local demo only verifies the Finder side of importing.

## API references

- [Authentication and rate limits](https://www.are.na/developers/explore)
- [Channel discovery](https://www.are.na/developers/explore/user/contents)
- [Upload flow](https://www.are.na/developers/resources/sdk)
- [Create a block](https://www.are.na/developers/explore/block/post-block)
- [Current OpenAPI specification](https://api.are.na/v3/openapi)

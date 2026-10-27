# Are.na x Finder

A native macOS Finder service for sending selected images to an Are.na channel.

Select images in Finder, choose **Services → Send to Are.na**, preview your selection, choose a channel, and send. Inspired by [Figma x Finder](https://github.com/behlock/figma-x-finder), with direct uploads through Are.na’s v3 API.

## Requirements

- macOS 13 or later.
- Xcode or the Xcode Command Line Tools, including Swift 5.9 or later.
- An Are.na account and a personal access token with **write** access.

## Install

From the project directory:

```sh
bash scripts/install.sh
open "$HOME/Applications/Are.na x Finder.app"
```

The installer builds the app, installs it in `~/Applications`, and registers the Finder service. You can pass another application directory as the first argument to the installer.

## Connect your account

1. Open [Are.na’s personal access token settings](https://www.are.na/settings/personal-access-tokens).
2. Create a token with **write** access.
3. Paste it into the app and click **Connect**.

The app validates the token against your profile and saves it in macOS Keychain. Tokens are never stored in the repository or the queue’s JSON file. Your account’s channels load one page at a time; click **Load more** for the next page. **Add channel URL…** lets you add a specific channel, including a shared channel you can contribute to.

If channel discovery is unavailable for your account, you can still add a channel by URL after connecting. A successful connection validates your identity; write access is checked when you send.

## Send images

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

- `Sources/ArenaCore`: API client, channel models, image preparation, durable queue, uploader.
- `Sources/ArenaFinder`: AppKit picker and previews, Finder service, Keychain integration.
- `Tests`: mocked API upload/recovery tests, queue persistence tests, preview behavior tests.
- `App/Info.plist`: app identity and Finder service registration.

For isolated local development, `ARENA_FINDER_DATA_DIR` overrides the queue directory. It does not change the Keychain entry. Avoid running multiple copies against the same data directory.

Tests use generated images and mocked HTTP responses. They do not upload to an Are.na account. A real authenticated upload still needs to be checked after connecting your token.

## Troubleshooting

- **Finder service missing:** open the app once, then check macOS Services settings for **Send to Are.na**. Re-run the installer if needed.
- **Access denied:** check the token’s write access and the channel’s contributor permissions.
- **Token revoked:** open **Account…** and connect with a new token.
- **Keychain prompt after rebuilding:** local builds use ad hoc signing, so macOS may ask again before granting access to the saved token.

## API references

- [Authentication and rate limits](https://www.are.na/developers/explore)
- [Channel discovery](https://www.are.na/developers/explore/user/contents)
- [Upload flow](https://www.are.na/developers/resources/sdk)
- [Create a block](https://www.are.na/developers/explore/block/post-block)
- [Current OpenAPI specification](https://api.are.na/v3/openapi)

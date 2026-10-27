# Are.na x Finder

Browse selected Are.na channels in Finder, preview files, and drag files into writable channels to upload.

## Install

Requires macOS 13+, Swift 5.9+, and an Apple Development signing identity. Website capture and thumbnail rendering are included in this repository; no other checkout or third-party package is required.

```sh
bash scripts/install.sh
open "$HOME/Applications/Are.na x Finder.app"
```

The installer signs and registers the Finder extension and starts the thumbnail helper. Set `ARENA_SIGNING_IDENTITY` to select a signing identity, or pass an application directory to `install.sh` to change the destination.

## Use

1. Create an Are.na [personal access token](https://www.are.na/settings/personal-access-tokens) with write access, then paste it into the app and connect.
2. Choose a channel and click **Add to Finder**, or use **Add by URL…**. Channels load as you scroll the picker.
3. Open **Are.na x Finder** under Finder’s Locations. Enable the provider if prompted.

- Connected channels appear as nested folders with their own upload permissions. Ancestor cycles remain web shortcuts.
- Opening a folder refreshes its listing, with a 15-second cache. Each folder contains up to 100 items; **More items** opens the next page.
- Images and attachments download when opened or copied. Text becomes Markdown; links become `.webloc` files with automatic website previews where possible.
- Copy or drag individual files up to **100 MB** into writable channel folders. Original bytes are preserved, and uploads continue with the panel closed.
- Remote rename, move, deletion, folder creation, and editing existing files are not supported.

Account settings and a manual **Refresh** fallback are in the macOS **Are.na x Finder** menu. **Review interrupted uploads…** appears there when an upload’s result needs checking before retrying. Known block IDs are retained to prevent duplicate uploads.

## Storage and previews

Tokens stay in the login Keychain, accessible to the signed app and extension. The channel catalog lives in `~/Library/Application Support/Are.na x Finder/channels.json`; upgrading preserves the retired `state.json` and queue files without using them for uploads.

Finder metadata, upload recovery, thumbnails, and count-only diagnostics live in `~/Library/Group Containers/<signing-team>.com.behlock.arena-x-finder/`. Browsing requests one folder page at a time; it does not mirror or crawl the account’s content.

The thumbnail helper renders visited channels’ website links in an isolated browser session without the Are.na token. Successful previews are cached for seven days; failures retry after a day. Sites may show sign-in screens or retain generic icons. To disable the helper:

```sh
launchctl bootout "gui/$(id -u)/com.behlock.arena-x-finder.thumbnails"
```

Also remove `~/Library/LaunchAgents/com.behlock.arena-x-finder.thumbnails.plist` to keep it disabled after login. Reinstalling enables it again.

## Development

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

The build produces `build/Are.na x Finder.app`. `ArenaCore` contains the API client, channel catalog, and credentials; `ArenaProvider` implements Finder browsing and uploads; `ArenaFinder` contains the panel and preview worker.

`ARENA_FINDER_DATA_DIR` overrides the app’s catalog directory, but not Keychain or the Finder domain. Tests use mocks and local files, never live Are.na uploads. To exercise the installed extension with a synthetic local domain:

```sh
"$HOME/Applications/Are.na x Finder.app/Contents/MacOS/Are.na x Finder" --finder-smoke
"$HOME/Applications/Are.na x Finder.app/Contents/MacOS/Are.na x Finder" --finder-remove-demo
```

If the smoke test reports disabled sync, enable **Are.na Demo** in Finder and rerun it. Removal preserves unsynced demo files.

## Troubleshooting

- **Access denied:** check the token’s write access and the channel’s contributor permissions. Reconnect through **Account…** if the token was revoked or the signing identity changed.
- **Finder location missing:** reinstall, add a channel, and enable the provider if prompted.
- **Stale folder:** reopen it, or use **Are.na x Finder → Refresh**.
- **Upload error:** check Finder’s file status and the app’s recovery menu before retrying.

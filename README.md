# Are.na x Finder

Your Are.na channels in Finder, with nested folders, website previews, and drag-and-drop uploads.

## Install

Requires macOS 13+, Swift 5.9+, and an Apple Development signing identity.

```sh
git clone https://github.com/behlock/arena-x-finder.git
cd arena-x-finder
bash scripts/install.sh
open "$HOME/Applications/Are.na x Finder.app"
```

## Use

1. Connect with an Are.na [access token](https://www.are.na/settings/personal-access-tokens) with write access.
2. Choose a channel and click **Add to Finder**, or paste its URL.
3. Browse **Are.na x Finder** in Finder’s Locations. Enable it if prompted.

Folders refresh when opened. Open **More items** for channels over 100 items. Drag files up to 100 MB into writable channels to upload.

Existing items are read-only. Account settings and upload recovery are in the macOS app menu. Tokens are stored in Keychain.

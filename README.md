# acui — Autocipher desktop app (Flutter)

The Flutter desktop client for [autocipher](https://github.com/PlanetLOF/autocipher):
an encrypted single-file vault (`.ac`) UI for Windows, macOS, and Linux.

All cryptography stays in Rust. The Flutter side is UI + a client over the
`autocipher_dart` wrapper package, which drives the native engine **in-process**
with `dart:ffi` over the per-op C ABI (`ac_version`, `autocipher_vault_*`). No
flutter_rust_bridge, no cargokit, no gRPC, no sidecar process.

- `autocipher_dart` (git override, see `pubspec.yaml`) — generated `Native.dart`
  bindings, the library loader, and the async `Vault` API. Heavy ops (Argon2id
  create/open/changePassword, folder imports, compact) run on worker isolates
  inside the wrapper, so they never block the UI.
- `lib/provider/` — riverpod state: the open `Vault` (`vaultSessionProvider`),
  connection-tab selection, file dialogs, random-password generation. Cloud
  support lives in `rclone_provider.dart` (rclone bridge), the cloud browser
  and the cloud-sync notifier.
- `lib/ui/` — provider-tab entry (FTP/FTPS, SFTP/SSH, cloud, local
  create/open), the vault browser (import/extract/preview/rename/delete), the
  cloud-sync banner, and settings (change password, compact, remirror,
  container info, rclone).
- `lib/ui/preview.dart` — pure-Dart preview-kind detection (image / SVG /
  video / text / binary), plus the image/video-name helpers that drive the
  grid & list thumbnails. Raster files show real thumbnails; video files show
  a generic movie icon (video decoding was removed along with media_kit).

## Repository split

This repo is **UI only**. The engine, the bridge, and the `autocipher_dart`
wrapper live in the [PlanetLOF/autocipher](https://github.com/PlanetLOF/autocipher)
monorepo. The app resolves the wrapper through a `dependency_overrides` git
override (see `pubspec.yaml`).

## Build the native engine

From the **autocipher monorepo**, build and stage your platform's release
library into the wrapper, where the app's build system picks it up:

```powershell
# Windows
script/build_ffi.ps1
```

```bash
# macOS / Linux
script/build_ffi.sh
```

This drops `autocipher_ffi` into `autocipher/dart/lib/src/native/<os>/`.

### Git dependency + pub cache staging

The git dependency never transports the binary (it's gitignored), yet the
wrapper's pubspec declares it as a Flutter asset — so `flutter test` /
`flutter build` fail unless the staged library is also inside the package that
pub resolved. After `flutter pub get` (and whenever the git ref or pub cache
changes), stage it once:

```bash
# Windows
pwsh script/stage_dev_native.ps1
# macOS / Linux (bash or zsh)
bash script/stage_dev_native.sh
```

`flutter build` then bundles it, and the build system also auto-stages it next
to the app on every build:

- **Windows** (`windows/CMakeLists.txt`): copies `autocipher_ffi.dll` beside
  the executable (loader plain-name lookup).
- **Linux** (`linux/CMakeLists.txt`): installs `libautocipher_ffi.so` into
  `bundle/lib/`, already on the runner's `$ORIGIN/lib` rpath.
- **macOS** (`AutocipherStageEngine` build phase): copies
  `libautocipher_ffi.dylib` into `Contents/Frameworks/` (on the app rpath).

Point the `AUTOCIPHER_NATIVE_LIB` CMake variable at another file (e.g. a shared
release build or a downloaded artifact) to override the default monorepo-staged
path. The loader's runtime `AUTOCIPHER_FFI_LIB` env var also works for quick
experiments (and is how the monorepo's engine tests find the library). If the
file is missing a build proceeds with a warning and no engine bundled.

## Cloud storage (rclone)

The **CLOUD** tab stores vaults on any rclone-backed cloud service — Google
Drive, OneDrive, Dropbox, Terabox, S3, WebDAV, … — as one encrypted `.ac`
blob per vault. The app shells out to the `rclone` binary (no SDK per
provider) and stays provider-agnostic: every operation talks to whatever
remotes exist in the user's `rclone.conf`.

- **Setup** — `rclone` must be installed and on `PATH` (or set explicitly in
  the rclone settings sheet). In the CLOUD tab, **NEW REMOTE…** opens
  rclone's own interactive `config` wizard in a terminal window; close it and
  tap **REFRESH** to pick the new remote.
- **Browse** — pick a remote, drill into folders, open or save-as any `.ac`
  vault, or **CREATE VAULT HERE** to make a new one directly in the current
  remote folder (name + password + KDF preset). Deleting a remote vault file
  is a whole-file delete; vaults are never placeholder-synced like OneDrive
  placeholders.
- **Cloud sessions** — opening a remote vault downloads it into a local cache
  (`<home>/acui/<remote>\<path>` by default: `C:\Users\<name>\acui\…` on
  Windows, `/Users/<name>/acui/…` on macOS, `/home/<name>/acui/…` on Linux;
  the destination
  folder is configurable from the rclone settings sheet, **CLOUD CACHE
  FOLDER**) and unlocks that copy; the engine works on the same single-file
  model as local vaults. The vault browser shows a sync banner with
  **SYNC NOW** and **Make a local copy…**.
- **Auto-sync** — after every mutation (import / extract / rename / delete /
  compact / change password / remirror) a debounced (2 s) upload pushes the
  updated `.ac` blob back to the cloud; the lock flow also offers
  **Upload & lock**.
- **Conflict guard** — before any upload the app stats the remote and, if it
  changed since it was opened (size or modtime), refuses to silently
  overwrite: you choose **Overwrite cloud** / **Reload from cloud** / make a
  local copy first. A conflict can never be clobbered by an auto-sync.

## Run

```bash
flutter pub get
flutter run -d windows   # or your desktop device
```

## Test

```bash
flutter analyze
flutter test
```

- `test/widget_test.dart` — provider-tab shell smoke test (renders and
  switches between the FTP/FTPS, SFTP/SSH, cloud, create, and open tabs).
- Engine coverage lives in the monorepo's `dart/test/` (wire-format parity +
  a live lifecycle through the real ABI).

## Windows note

Bundling the `file_selector` plugin requires
[Developer Mode](https://learn.microsoft.com/windows/apps/get-started/enable-your-device-for-development)
(symlink support): `start ms-settings:developers`. UI plugin bundling is the
only thing that needs it — `flutter test` do not.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). SPDX-License-Identifier: GPL-3.0-or-later
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
  connection-tab selection, file dialogs, random-password generation.
- `lib/ui/` — provider-tab entry (FTP/FTPS, SFTP/SSH, local create/open), the
  vault browser (import/extract/preview/rename/delete), and settings (change
  password, compact, remirror, container info). Import accepts files and
  folders both from the native dialogs and by dragging them onto the browser
  (drop lands in the folder you're currently viewing).
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
  switches between the FTP/FTPS, SFTP/SSH, create, and open forms).
- Engine coverage lives in the monorepo's `dart/test/` (wire-format parity +
  a live lifecycle through the real ABI).

## Windows note

Bundling the `file_selector` plugin requires
[Developer Mode](https://learn.microsoft.com/windows/apps/get-started/enable-your-device-for-development)
(symlink support): `start ms-settings:developers`. UI plugin bundling is the
only thing that needs it — `flutter test` do not.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). SPDX-License-Identifier: GPL-3.0-or-later
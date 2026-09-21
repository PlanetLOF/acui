# Stage the local FFI engine build into the pub-cache git checkout of
# autocipher_dart.
#
# The git dependency cannot carry the native binary (it is gitignored in the
# monorepo), but the wrapper's pubspec declares it as a Flutter asset, so
# `flutter test` / `flutter build` fail unless the staged library exists inside
# the package that pub resolves. This script copies it there.
#
# Run after `flutter pub get` whenever the git ref or the pub cache changes.
#
# Usage:
#   pwsh script/stage_dev_native.ps1
#   pwsh script/stage_dev_native.ps1 -AutocipherRoot C:\path\to\autocipher
param(
    [string]$AutocipherRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\autocipher"))
)

$ErrorActionPreference = "Stop"

$os = if ($IsWindows) { "win" } elseif ($IsLinux) { "linux" } else { "macos" }
$name = if ($IsWindows) { "autocipher_ffi.dll" } elseif ($IsLinux) { "libautocipher_ffi.so" } else { "libautocipher_ffi.dylib" }

$src = Join-Path $AutocipherRoot "dart" "lib" "src" "native" $os $name
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "staged engine not found at $src (run script/build_ffi.ps1/.sh in the autocipher repo first)"
    exit 1
}

$pkg = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Pub\Cache\git") -Directory -Filter "autocipher-*" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $pkg) {
    Write-Error "no autocipher_dart checkout in the pub cache (run flutter pub get first)"
    exit 1
}

$dstDir = Join-Path $pkg.FullName "dart" "lib" "src" "native" $os
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir $name) -Force
Write-Host "staged $src -> $(Join-Path $dstDir $name)"
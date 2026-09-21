# OpenAvalon Windows local-feed notes

This checkout is used to prepare the local NuGet feed consumed by OpenDevelop's Windows release.
Upstream scripts are primarily macOS-oriented. Do not copy their platform assumptions into this
workflow: the default here is Windows-only, and a release payload must support both `win-x64` and
`win-arm64`.

## Required workstation tools

- .NET SDK selected by `LibreWPF/global.json` (currently .NET 10).
- Git for Windows Bash. Invoke the Bash scripts with
  `C:/Program Files/Git/bin/bash.exe`; do not run them in PowerShell directly.
- Visual Studio 2026 Community (VS 18) with the minimal **Desktop development with C++** toolchain:
  MSBuild, MSVC C++ build tools, Windows SDK, and C++/CLI support. `WindowsFormsIntegration` is
  C++/CLI, so a normal `dotnet msbuild` discovery path is insufficient.

The scripts expect these installed locations when running on Windows:

```text
C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Current/Bin/MSBuild.exe
C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Microsoft/VC/v180
```

`dist.local.sh` sets `VCTargetsPath`, uses VS MSBuild for LibreWPF validation graphs, supplies the
required `ijwhost.dll`, and sets `CL=/MP1`. Keep `/MP1`: the native `System.Printing` PCH otherwise
causes excessive concurrent C++ compiler memory use on this workstation.

## Standard Windows feed preparation

From this repository root:

```bash
"C:/Program Files/Git/bin/bash.exe" ./dist.local.sh
```

Important defaults in this fork:

- `DIST_LOCAL_TARGET_PLATFORM=windows` is the default. It sets
  `PROGPU_PACKAGE_WINDOWS_ONLY=1` and `ProGpuNativePackageWindowsOnly=true`; it must not claim
  Linux/macOS assets exist.
- Packages publish to `artifacts/local-feed` by default and are registered as the
  `openavalon-local` NuGet source.
- The aligned versions currently used by OpenDevelop are
  `PROGPU_WPF_DEV_PACKAGE_VERSION=0.1.0-preview.57` and
  `PROGPU_WPF_PROGPU_PACKAGE_VERSION=0.1.0-preview.62`. Change them as one coherent package graph,
  never one package at a time.
- The canonical integration script disables the pinned ApiCompat checks
  (`RunNetFrameworkApiCompat=false`, `RunRefApiCompat=false`) because the newer private LibreWPF
  SDK's generated reference data is incompatible with that older tool. This is a local-feed
  compatibility constraint, not an upstream policy change.

Before a build, update the superproject and initialize the pinned nested repositories. The
canonical gate verifies that LibreWPF's LibreWinForms commit and LibreWinForms' ProGPU commit match;
do not bypass those checks with an arbitrary external checkout.

## Dual-architecture canonical WindowsFormsIntegration

`LibreWinForms.WindowsFormsIntegration.dll` and several ProGPU bridge assemblies are
architecture-specific. A single `lib/net10.0` asset cannot serve both x64 and ARM64. Build separate
canonical feeds; do not overwrite one architecture with the other.

`dist.local.sh` currently produces the ARM64 canonical feed by default:

```text
artifacts/canonical-winforms-feed
```

Build the x64 peer explicitly when preparing a dual-architecture OpenDevelop release:

```bash
PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_OUTPUT='C:/Users/lextudio/source/repos/wpf-tools/openavalon/artifacts/canonical-winforms-feed-x64' \
PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_VERSION='0.1.0-preview.57' \
PROGPU_WPF_CANONICAL_PROGPU_PACKAGE_VERSION='0.1.0-preview.62' \
PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM='x64' \
DOTNET_INSTALL_DIR='C:/Users/lextudio/source/repos/wpf-tools/openavalon/LibreWPF/.dotnet' \
PROGPU_WPF_RUN_DRAWING_QUALITY_GATES=0 \
"C:/Program Files/Git/bin/bash.exe" LibreWPF/eng/progpu-wpf-canonical-winforms-integration.sh
```

For ARM64, use the same command with output
`artifacts/canonical-winforms-feed` and `PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM=ARM64` (or use the
default `dist.local.sh` Windows path).

OpenDevelop's `build/patch-librewinforms-deps.ps1` consumes both feeds and places their managed
assets under `runtimes/win-x64/lib/net10.0` and `runtimes/win-arm64/lib/net10.0`, with matching
`runtimeTargets` entries in `.deps.json`. Keep the two feeds available until OpenDevelop packaging
has completed. Do not flatten these DLLs into a single RID-neutral local-feed path.

## Verification and common failures

- Confirm both canonical feeds contain the same package IDs/versions, but that PE machine types are
  `8664` (x64) and `AA64` (ARM64), respectively, for `ProGPU.Backend.dll` and
  `WindowsFormsIntegration.dll`.
- The consumer package's root `ProGPU.Wpf.Interop.dll` must be the explicit `LibreWPF.Interop`
  package version, not the older convenience copy carried by `LibreWPF.Transport`.
- `LibreWPF.Transport` can contain `System.Private.Windows.Core` v10 while the current
  LibreWinForms graph requires v11. OpenDevelop's dependency patcher must restore the v11 file and
  metadata from `LibreWinForms.System.Windows.Forms` after copying the transport payload; otherwise
  startup fails with `FileNotFoundException` for `System.Private.Windows.Core, Version=11.0.0.0`.
- Do not delete the global NuGet cache as a response to a restore/build mismatch. First verify the
  local source, package versions, nested-repository commits, and architecture-specific canonical
  feeds.

`dist.local.sh` removes/recreates its canonical feed directory and overwrites same-version packages
in the local feed. Treat it as a release-preparation operation; do not run it concurrently with an
OpenDevelop package build that is consuming those files.

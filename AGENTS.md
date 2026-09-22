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

## Packing invariants `dist.local.sh` enforces

The consuming repository documents the whole contract — one OpenDevelop payload serving both x64
and ARM64, which assets belong in `lib/`, `ref/` and `runtimes/<rid>/`, the NuGet global-cache
trap, and the steps for rebasing this fork onto upstream dotnet/wpf — in
`OpenDevelop/doc/technotes/dual-architecture-packaging.md`. Read it before changing anything that
packs an assembly.

Each of these was a real failure that produced no error at the point it went wrong, so the guards
matter more than the rules:

- **Pack AnyCPU.** Everything `pack_wpf_project` produces carries its managed assemblies in a
  RID-neutral `lib/<tfm>` folder. A hardcoded `-p:Platform=x64` shipped an x64 `ProGPU.Wpf.dll`
  from an ARM64 workstation; the consumer then failed at startup with "Could not load file or
  assembly 'ProGPU.Wpf' ... The system cannot find the file specified" for a file that was
  present. The `Checking RID-neutral payload is AnyCPU` step at the end of the run lists any
  `lib/**/*.dll` whose PE machine field is not `0x014C`. The genuinely architecture-specific
  assemblies below are the documented exception and ship under `runtimes/<rid>/`.
- **`lib/` was not the only folder making that promise.** The audit (now `Checking payload
  architectures`) covers three, because the same `Platform=x64` build violated all three and only
  one of them fails the way the rule above describes:
  - `lib/<tfm>/` — AnyCPU only; a violation is a run-time load failure.
  - `ref/<tfm>/` — AnyCPU only; a violation is a **compile-time** `CS8012: Referenced assembly 'X'
    targets a different processor`. That is merely a warning in most projects, so an x64 `ref/`
    tree looks harmless right up until it reaches one with `TreatWarningsAsErrors` — in
    OpenDevelop, `AvalonDock.Themes.VS`, which it broke with four errors while nothing else in the
    solution complained. It is latent too: projects already built against the previous package do
    not recompile until something else invalidates them.
  - `runtimes/<rid>/lib/<tfm>/` — AnyCPU or that RID's own architecture, never another's.
    `StageLibreWpfRidManagedTransportPayload` duplicates ONE managed payload into all three RID
    folders so a RID-less build gets a complete RID-filtered asset set; that is correct only while
    the payload is AnyCPU.

  Both were the same two gaps in the `LibreWpfArchNeutralTransportAssemblies` whitelist in
  `eng/WpfArcadeSdk/Sdk/Sdk.props`, and both are now closed there rather than in the audit:
  - The whitelist lists **implementation** assembly names, but the reference projects are
    `src/Microsoft.DotNet.Wpf/src/*/ref/<name>-ref.csproj`, so `MSBuildProjectName` is
    `WindowsBase-ref` and never matched. Reference assemblies are now AnyCPU unconditionally, by
    the `-ref` suffix — a wider rule than the whitelist, resting on a different fact: a reference
    assembly is compiled against and never loaded, so its machine field can only do harm.
  - `Microsoft.Win32.SystemEvents` was simply missing from the whitelist. It is pure managed code
    that ships in `lib/` and is duplicated into all three RID folders, so one stamp landed in
    three places, two of which could not load it.

  Keep the audit anyway: it reports rather than fails, and it is what turns the next such gap into
  a line of output instead of a `CS8012` in one unrelated consumer project weeks later.
- **The consumer SDK must prefer `runtimes/<rid>/` over `lib/`, in BOTH branches.**
  `_ProGpuWpfSdkCopyManagedTransportRuntimeAssets` in `ProGPU.Wpf.Sdk.targets` runs after NuGet has
  already placed the correct per-RID assets, so copying `lib/` wholesale silently overwrote them —
  the arm64 `DirectWriteForwarder` copied first, the x64 one over it moments later, and the ARM64
  test host then died on a file plainly present in `bin`. Two details made the fix look ineffective:
  guarding it on `'$(RuntimeIdentifier)' == ''` skips exactly the branch that does the damage (real
  consumer projects evaluate to `win-arm64`), and composing the per-RID root from
  `PkgLibreWPF_Transport` or a package root yields an empty path in that target — the `lib/` root is
  commonly reached through the `ref/`→`lib/` rewrite instead — so the preference silently does
  nothing. Derive the sibling tree from whichever `lib/` root was actually resolved, and verify by
  reading the PE machine of the DLL in the consumer's `bin`, after clearing
  `~/.nuget/packages/librewpf.sdk/<version>`.

  Do **not** reach for `PlatformTarget` as the architecture signal, even though it reads like the
  obvious one. A project with `ProGpuWpfUseCurrentRuntimeIdentifier=true` derives its RID from the
  architecture of the building process, so an x64 IDE on an ARM64 machine emits an x64 apphost
  while `PlatformTarget` still evaluates to `arm64`; preferring it then pairs an arm64
  `DirectWriteForwarder` with an x64 `.exe` - the same breakage, arrived at from the other side.
- **Never copy anything out of `ref/` into an output folder.** A reference assembly has no method
  bodies and the runtime refuses it outright (`BadImageFormatException: Reference assemblies cannot
  be loaded for execution`), thrown from the bootstrap before any application code runs. This is
  not hypothetical: the SDK's runtime roots are partly derived by rewriting a `ref/` path into a
  `lib/` one, and when the anchor property arrives as `"<...>\ref\net10.0\X.dll;<...>\ref\net10.0"`
  the semicolon makes MSBuild read the Include as two items, the first of which is a reference
  assembly. A 96 KB `WindowsBase.dll` then replaces the 1 MB implementation in `bin`. Both the
  copy target and the deps target now filter on the resolved path, so it cannot matter how an item
  got there.
- **AnyCPU is also required for the arch-neutral packages to pack at all.**
  `packaging/Directory.Build.props` sets `IsPackable=false` when `$(Platform)` is an architecture
  and `$(CreateArchNeutralPackage)` is true. With an architecture forced, `dotnet pack` skipped
  `LibreWPF.Transport` and `LibreWPF.Sdk` silently **and still exited 0** - and since the old
  `.nupkg` is deleted first, the feed lost both packages. `pack_wpf_project` now asserts the
  artifact exists instead of trusting the exit code.
- **Clear the transport staging tree before building it.** `LibreWPF.Transport` is zipped from
  `artifacts/packaging/Release/LibreWPF.Transport`, and its own cleanup target excludes the
  current TFM's folder, so the tree is additive. A stale `ProGPU.Wpf.Interop.dll` survived there
  for two weeks and shipped next to a newer `PresentationFramework.dll` that called an interop API
  it did not have.
- **`librewinforms-pack.sh` gets its own output directory.** It rejects any package it does not
  own ("Unexpected current-version package artifact"), so it cannot write straight to the shared
  feed; it writes `artifacts/librewinforms-feed` and the result is copied into `local-feed`.
- **`LIBREWINFORMS_CANONICAL_WFI_COMMIT` is LibreWPF's HEAD, not LibreWinForms'.**
  WindowsFormsIntegration is built from the LibreWPF tree, so SourceLink records LibreWPF's
  commit; `librewinforms-pack.sh` checks the LibreWinForms side separately against its own HEAD.

The last two abort *after* deleting the packages they were about to republish, so a failure there
leaves the feed missing `LibreWPF.Interop` and `LibreWinForms.WindowsFormsIntegration` and the
next consumer restore fails with NU1101. Re-run the pack rather than investigating the NuGet
source.

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

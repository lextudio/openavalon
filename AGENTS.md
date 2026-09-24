# OpenAvalon local-feed notes

This checkout prepares the local NuGet feed (`artifacts/local-feed`, registered as the
`openavalon-local` source) that OpenDevelop consumes. One script, `dist.local.sh`, serves both
supported hosts and picks the lane from the host it runs on:

| Host | Lane (`DIST_LOCAL_TARGET_PLATFORM`) | Native slices shipped | Canonical WindowsFormsIntegration |
|---|---|---|---|
| Git for Windows Bash | `windows` | `win-x64` + `win-arm64` | two feeds: ARM64 and x64 |
| macOS on Apple silicon | `macos` | `osx-arm64` only | one feed, built without a platform (AnyCPU) |
| anything else | `all` (upstream) | every desktop RID | one feed |

Override the lane with `DIST_LOCAL_TARGET_PLATFORM` only to reproduce another lane deliberately.
The macOS lane refuses to run on an Intel Mac: there is no osx-x64 release.

## Shared preparation

- .NET SDK selected by `LibreWPF/global.json`; the scripts use `LibreWPF/.dotnet` when present.
- Update the superproject and initialize the pinned nested repositories
  (`git submodule update --init --recursive`). The canonical gate requires LibreWPF's ProGPU and
  LibreWinForms' ProGPU to be the **same commit**, and `librewinforms-pack.sh` requires the
  canonical WFI to have been built from LibreWinForms' current HEAD. When ProGPU changes, advance
  it in both places; do not commit into a nested repository while a feed build is running, or
  the last step fails with "Canonical WFI was not qualified against LibreWinForms commit ...".
- Versions: LibreWPF/LibreWinForms use `PROGPU_WPF_DEV_PACKAGE_VERSION` (default
  `0.1.0-preview.57`); ProGPU's version is read from `ProGPU/Directory.Build.props`
  (`VersionPrefix`-`VersionSuffix`) unless `PROGPU_WPF_PROGPU_PACKAGE_VERSION` overrides it. The
  run prints both first (`== Package versions: ... ==`). The feed publishes what the sources are
  now; never lower a version to match a consumer's pin — earlier versions already in the feed stay
  in place so older pins keep restoring. `LibreWPF.Sdk` is packed with
  `ProGpuPackageVersion=<ProGPU version>` so its consumers restore the ProGPU packages this feed
  just produced. Republish over the same version rather than inventing a side version.
- Scripts must run under macOS's stock bash 3.2 as well as Git for Windows Bash (bash 5): no
  associative arrays (`declare -A`), `mapfile`, or `${var,,}`.
- The canonical integration script disables the pinned ApiCompat checks
  (`RunNetFrameworkApiCompat=false`, `RunRefApiCompat=false`) because the newer private LibreWPF
  SDK's generated reference data is incompatible with that older tool. This is a local-feed
  compatibility constraint, not an upstream policy change.
- MSBuild `Exec` commands that pass paths must use `/`, never `\`: on macOS the shell eats the
  backslashes (`MS\Internal\IO\...` became `MSInternalIO...` in WindowsBase's string-table
  generator). This only shows up on a clean intermediate directory, so incremental builds hide it.

## Windows lane

Required workstation tools:

- Git for Windows Bash. Invoke the Bash scripts with `C:/Program Files/Git/bin/bash.exe`; do not
  run them in PowerShell directly.
- Visual Studio 2026 Community (VS 18) with the minimal **Desktop development with C++** toolchain:
  MSBuild, MSVC C++ build tools, Windows SDK, and C++/CLI support. `WindowsFormsIntegration` is
  C++/CLI, so a normal `dotnet msbuild` discovery path is insufficient.

The scripts expect these installed locations:

```text
C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Current/Bin/MSBuild.exe
C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Microsoft/VC/v180
```

`dist.local.sh` sets `VCTargetsPath`, uses VS MSBuild for LibreWPF validation graphs, supplies the
required `ijwhost.dll`, and sets `CL=/MP1`. Keep `/MP1`: the native `System.Printing` PCH otherwise
causes excessive concurrent C++ compiler memory use.

```bash
"C:/Program Files/Git/bin/bash.exe" ./dist.local.sh
```

The Windows lane sets `PROGPU_PACKAGE_WINDOWS_ONLY=1` and `ProGpuNativePackageWindowsOnly=true`;
it validates and ships the `win-x64` and `win-arm64` native payloads (including Direct2D) and must
not claim Linux/macOS assets exist. Before packing ProGPU it builds those payloads itself, so a
clean checkout does not depend on an earlier developer build's `artifacts/` tree:

- **Native renderer** — `ProGPU/eng/build-progpu-native-windows.ps1 -Rid <rid> -Compiler MSVC
  -BuildOnly` for each RID, after deleting `artifacts/progpu-native/build-<rid>` (a cached ClangCL
  choice from an interactive attempt must not be reused). Asserts `progpu_native.dll`,
  `progpu_native_dawn.dll` and `progpu_native_direct2d.dll` were staged.
- **DX12 runtime** — `ProGPU/eng/build-progpu-dx12-runtime-windows.ps1 -Rid <rid>`, which verifies
  the pinned Rust dependency, signed compiler package, hashes, PE architecture and provenance
  receipts. Each stage refuses an existing output directory, so the script clears
  `artifacts/progpu-dx12/{libclang,dependency,compiler,package}/<rid>`; `download/` and
  `artifacts/wgpu-native-windows` are verified caches and are kept. Asserts `wgpu_native.dll`,
  `dxcompiler.dll`, `dxil.dll` and a `progpu-dx12-runtime.json` receipt naming the same RID.
- **Cross-architecture toolchains** — each slice needs a PowerShell and a rustup of its own
  architecture. The host architecture is read from the registry, because Git for Windows Bash is
  an x64 process and reports `AMD64` under emulation on an ARM64 machine. On an ARM64 host the x64
  slice needs an x64 `pwsh`: `PROGPU_WPF_X64_PWSH`, else `artifacts/tools/pwsh-x64/runtime/pwsh.exe`.
  rustup comes from `PROGPU_WPF_<X64|ARM64>_RUSTUP_BIN` (with `..._RUSTUP_HOME` /
  `..._CARGO_HOME`), else `artifacts/tools/rustup-<arch>/{cargo-home,rustup-home}`, else `rustup`
  on `PATH`.

It then regenerates the per-RID managed runtime payload with
`eng/progpu-wpf-windows-managed-runtime.ps1` and builds both canonical WinForms slices (below).
Every one of these PowerShell steps is followed by an artifact check, because `pwsh -File` can
exit 0 after a terminating error.

## macOS lane

```bash
./dist.local.sh
```

- Apple silicon only. Native payload validation requires `osx-arm64` alone
  (`PROGPU_PACKAGE_GROUP=opendevelop-macos`); Windows-only Direct2D is intentionally not staged,
  so that lane packs `ProGPU.Backend.Native` with `ProGpuNativeSkipRuntimeValidation=true`.
  `ProGPU.Backend.Dawn` is part of the closure because `ProGPU.Backend.Native` depends on it.
- Managed code is built **without a platform**. Do not export `Platform=x64`/`ARM64` on macOS: it
  leaks into the ProGPU project graph, whose `obj/<platform>/` reference assemblies are then never
  produced (`CS0006: Metadata file '.../ProGPU.WinRT/obj/x64/...' could not be found`). macOS has
  no `PROCESSOR_ARCHITECTURE`, which is why the canonical script used to guess `x64` here. The
  AnyCPU assemblies run natively on Apple silicon.
- The canonical WinForms graph runs **before** the transport build on macOS.
- `LibreWPF.Sdk` links a small C shim. The default Command Line Tools SDK fails it with
  "ld: tapi error: malformed file / unknown architecture", so the script pins
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` (or `MacOSX26.sdk`) when
  `SDKROOT` is unset. Consumer apps that use `LibreWPF.Sdk` need the same `SDKROOT`.

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

## Dual-architecture canonical WindowsFormsIntegration (Windows lane)

`WindowsFormsIntegration.dll` is C++/CLI, and several ProGPU bridge assemblies are
architecture-specific, so the Windows release needs one canonical feed per architecture.
`dist.local.sh` builds both, x64 first and ARM64 last:

```text
artifacts/canonical-winforms-feed-x64   PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM=x64
artifacts/canonical-winforms-feed       PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM=ARM64
```

`librewinforms-pack.sh` qualifies against the ARM64 feed. The paths can be moved with
`DIST_LOCAL_CANONICAL_WINFORMS_FEED` and `DIST_LOCAL_CANONICAL_WINFORMS_FEED_X64`. Do not overwrite
one architecture with the other.

OpenDevelop's `build/patch-librewinforms-deps.ps1` takes the two feeds as
`-WindowsArm64PackageRoot` and `-WindowsX64PackageRoot` and places their managed assets under
`runtimes/win-arm64/lib/net10.0` and `runtimes/win-x64/lib/net10.0`, with matching
`runtimeTargets` entries in `.deps.json`. Keep both feeds available until OpenDevelop packaging has
completed, and do not flatten these DLLs into a single RID-neutral local-feed path.

When the canonical script runs on its own, `PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM` selects the
slice; if it is unset, Windows follows `PROCESSOR_ARCHITECTURE` and other hosts build without a
platform. `LibreWinForms.WindowsFormsIntegration.Package` treats an empty platform and the
MSBuild default `AnyCPU` alike and then reads the platform-less output directory.

## Verification and common failures

- Windows: confirm both canonical feeds contain the same package IDs/versions, but that PE machine types are
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

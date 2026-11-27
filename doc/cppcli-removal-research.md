# Removing C++/CLI (and native C++ builds) from LibreWPF — research

Status: implemented. The default LibreWPF build is fully managed and ships from pin `5ad647e34`.
The TL;DR and sections 1-5 are the original research against `2139ab8e0`; "Status after
implementation" below supersedes them. Verified with `git ls-files` / `git grep`; items marked
**(unverified)** were inferred at the time.

## TL;DR

* Only **two** C++/CLI projects exist (`CLRSupport=NetCore`): `DirectWriteForwarder` and
  `System.Printing`. Everything else with a `.vcxproj` (33 projects: all of `WpfGfx/*`, `PenImc`,
  `PresentationNative`, `D3DCompiler`, `VCRuntime`) is plain native C++ and is **not built by the
  openavalon closure**: the Windows native DLLs (`wpfgfx_cor3`, `PresentationNative_cor3`, `PenImc_cor3`, ...) are
  repacked from the `Microsoft.WindowsDesktop.App.Runtime.win-{x64,arm64}` NuGet packages
  (`packaging/Microsoft.DotNet.Wpf.GitHub/Microsoft.DotNet.Wpf.GitHub.ArchNeutral.csproj`).
* `WindowsFormsIntegration` is **no longer C++/CLI**: it is a C# project
  (`src/LibreWPF.WinFormsCompat/WindowsFormsIntegration/WindowsFormsIntegration.csproj`) and is already in
  the AnyCPU whitelist (`eng/WpfArcadeSdk/Sdk/Sdk.props`). The `dist.local.sh` comment calling it C++/CLI and the
  dual canonical feed are stale reasoning (the arm64/x64 assemblies are byte-identical per Sdk.props).
* **`System.Printing` C++/CLI is effectively already out of the shipped package.** The shipped
  `System.Printing.dll` comes from the C# cycle-breaker `System.Printing-PresentationFramework-api-cycle`
  (16-line `PrintQueue` stub) plus `System.Printing-ref`
  (`packaging/.../Directory.Build.targets:182-199`). The vcxproj is only compiled on Windows because
  `PresentationUI.csproj:174` references it, and PresentationUI is one of the per-RID "transport" projects in
  `eng/progpu-wpf-windows-managed-runtime.ps1`. **(unverified)** whether the vcxproj output ends up in any
  published asset; the ArchNeutral csproj only picks `PresentationCore.dll` + `DirectWriteForwarder.dll` out of
  `artifacts/windows-managed-runtime`.
* **`DirectWriteForwarder` is the one real blocker.** It is why a Windows runner + Visual Studio/MSVC, ijwhost,
  per-RID PresentationCore, and the `stage-windows-managed-runtime` CI job exist at all. PresentationCore on
  Windows is *compiled differently* (`'$(OS)' == 'Windows_NT'`: DirectWrite) from the non-Windows build (portable SFNT
  text), hence a second, per-RID, mixed-mode PresentationCore.

## 1. Inventory

| Project | Kind | Provides | Managed dependents | macOS/Linux | Windows build/package today |
|---|---|---|---|---|---|
| `src/DirectWriteForwarder` (103 files; `CPP/DWriteWrapper`, `TrueTypeSubsetter/TtfDelta`) | **C++/CLI** | Managed wrapper over DirectWrite: factory, font collection/face/family, text analyzer, itemizer, glyph/metrics types (`MS.Internal.Text.TextInterface.*`), TrueType subsetter for XPS | `PresentationCore` (`MS/internal/Text/TextInterface/*`, FontCache, Shaping, TextFormatting; ~33 files use `TextInterface`), `PresentationFramework`, `ReachFramework` (project refs gated `OS==Windows_NT`) | Not built. PresentationCore compiles `PortableTextInterface.cs` (2454 lines) + ProGPU.Text SFNT shaper/subsetter instead (`PresentationCore.csproj:283-325`) | Built per RID (x64, arm64) by `eng/progpu-wpf-windows-managed-runtime.ps1` through VS MSBuild; packaged to `runtimes/<rid>/lib/net10.0` with `ijwhost.dll` and a copy of the desktop-runtime natives |
| `src/System.Printing` (174 files; `CPP/src`, `GDIExporter`) | **C++/CLI** | Real print system: `LocalPrintServer`, `PrintQueue`, driver/job thunks, GDI exporter (`gdi*.cpp`), `PrintTicket` plumbing | `ReachFramework` (resources only; real API is not referenced), `PresentationFramework` (`PrintDialog`, `Win32PrintDialog`, `DocumentViewerBase`, ...) via `System.Printing-ref`, `PresentationUI` (vcxproj on Windows, ref on non-Windows) | Not built; non-Windows uses the `-ref` C# project | Compiled as a PresentationUI dependency on the Windows runner; shipped `System.Printing.dll` is the C# stub **(see TL;DR caveat)** |
| `src/WpfGfx/**` (MIL: `wpfgfx.vcxproj`, `milctrl`, `api`, `av`, `core/*`, `fxjit/*`, ...; ~25 static libs) | native C++ | Windows composition engine ("MIL", D3D9/software rasteriser, `wpfgfx_cor3.dll`) | PresentationCore `DllImport wpfgfx_cor3` (~208 DllImports across the three natives) | Never built. `ProGPU.Wpf/Composition/Mil` reimplements the channel contract; `PortableWpfRuntime` selects `Portable` on non-Windows | **Not built here**; `wpfgfx_cor3.dll` is copied from `Microsoft.WindowsDesktop.App.Runtime`. Windows still defaults to `PortableWpfMediaBackend.WindowsMil` |
| `src/PenImc` (+ `tablib`) | native C++ | Pen/touch/stylus COM bridge (`PenImc_cor3`) | `PresentationCore` Wisp stylus (`PenImcRcw.cs`, `UnsafeNativeMethodsPenimc.cs`) | Not built; `InputManager.UsesPortableInput` skips Wisp | Not built; native copied from runtime package |
| `redist/PresentationNative` | native C++ | `PresentationNative_cor3` (shell/imaging/clipboard helpers) | PresentationCore/Framework DllImports | Not built | Copied from runtime package |
| `redist/D3DCompiler`, `redist/VCRuntime`, `Shared/OSVersionHelper`, `WpfGfx/exts`, `DbgXHelper`, `DebugLib`, ... | native C++ | Redistribution shims / debug helpers | native only | Not built | Not built |
| `WindowsFormsIntegration` | **C# now** | WinForms host | PresentationFramework consumers | Built as C# compat shim | AnyCPU; already pure managed |

Confirmed substitutes already in the tree on non-Windows: `ProGPU.Text` (SFNT parsing/shaping/subsetting),
`ProGPU.Wpf/Composition/Mil`, `ProGPU.Compatibility`, `PortableTextInterface`, `PortableTextLine`, portable
FlowDocument layout, portable input.

## 2. Replacement paths

### A. DirectWriteForwarder (priority 1)

Options, in increasing effort:

1. **Use the portable text stack on Windows too (drop DWF entirely).**
   Make PresentationCore build once (`'$(OS)' != 'Windows_NT'` branches become unconditional), delete the DWF
   project refs in PresentationCore/Framework/Reach, delete the per-RID PresentationCore. Effort: low in build
   plumbing, medium in validation. Risk/what breaks: text fidelity on Windows differs from DirectWrite
   (ClearType/GDI-compatible metrics, font fallback, system font collection, complex-script shaping, OpenType features,
   variable fonts). ProGPU.Text shaper is "simple SFNT" (`SfntSimpleGlyphShaper`), so complex scripts
   (Indic, Arabic edge cases) would regress compared with DirectWrite. Good option if Windows already runs the
   portable backend in OpenDevelop; verify that first (it is the same ProGPU renderer story as macOS).
2. **Managed DirectWrite via COM (recommended long-term for Windows fidelity).**
   The managed half already exists: `DWriteInterfaces.cs`, `DWriteLoader.cs`, `DWriteUtil.cs`, `Factory.cs`,
   `FontCollectionLoader.cs` are compiled into PresentationCore on Windows. What DWF adds is the C++/CLI
   object model (about 25 wrapper types: `Font*`, `FontFace`, `TextAnalyzer`, `TextItemizer`, `ItemProps`, ...)
   and the TrueType subsetter. Re-implement those wrappers in C# using `[GeneratedComInterface]` /
   `ComWrappers` (or `LibraryImport` + vtables), and port `TtfDelta` subsetting to C# (or reuse
   `ProGPU.Text.SfntFontSubsetter`, already linked for non-Windows). Effort: medium-large (2-4 weeks, mostly
   mechanical translation + behaviour tests). Risk: COM lifetime/apartment bugs, exception-translation differences
   (HRESULT -> managed), perf of marshalling in hot shaping paths. Result: single AnyCPU PresentationCore, no ijwhost,
   no per-RID payload.
3. Hybrid: option 2 for Windows, runtime switch to option 1 as fallback (an `OperatingSystem.IsWindows()` choice instead of a compile-time one),
   which also allows one PresentationCore binary for all platforms.

What disappears with DWF gone: the Windows-only `stage-windows-managed-runtime` job, `progpu-wpf-windows-managed-runtime.ps1`,
`runtimes/<rid>/lib/net10.0` PresentationCore/DWF/ijwhost payload, the `Wpf.Cpp.targets` C++/CLI handling.

### B. System.Printing (priority 2, mostly already done)

* Shipping path is already managed. Remove the remaining Windows-only vcxproj reference in
  `PresentationUI.csproj:174-176` (use the `System.Printing-ref` branch unconditionally, as non-Windows does) and drop
  the "(with System.Printing)" special case in the managed-runtime script. Effort: trivial; **risk**: `PresentationUI`
  (XPS DocumentApplication viewer) would lose the real implementation at runtime on Windows; check whether anything
  loads `System.Printing` types from PresentationUI in OpenDevelop (unlikely).
* Functional printing (real `LocalPrintServer`/`PrintQueue`/`PrintDialog`, GDI exporter) is **not available** from the shipped stub today.
  If printing is ever needed: reimplement as managed P/Invoke over `winspool.drv` + `PrintTicket` XML, or keep upstream
  `System.Printing` from the `Microsoft.WindowsDesktop.App.Ref/Runtime` package (it is a prebuilt, binary-compatible assembly the repo
  already downloads for natives). Effort: large for a faithful port; cheap if the runtime package assembly is reused.

### C. WpfGfx/MIL, PenImc, PresentationNative, D3DCompiler, VCRuntime (priority 3, "drop from builds")

* They are not part of this build; the cleanup is deleting dead references, not porting.
  `WpfProjectReference.targets` (`PresentationNative_cor3`, `PenImc_cor3` project paths) and `ShippingProjects.props` are upstream
  leftovers; the `ArchNeutral` csproj depends on the *upstream runtime NuGet packages* for these natives.
* **Real dependency to retire:** Windows still defaults to `WindowsMil` (`PortableWpfRuntime`), so the Windows build needs prebuilt `wpfgfx_cor3`
  and `PresentationNative_cor3` from Microsoft's package (also x86 listed in `eng/progpu-preview-package-audit.sh` while x86 is "not shipped" — drift).
  Eliminating that means making `Portable` the Windows default (ProGPU.Wpf/Composition/Mil), which is a product decision: loses
  MIL features (some effects/RenderTargetBitmap behaviours, `HwndTarget` composition) and Wisp stylus/touch (PenImc) unless ported to
  WM_POINTER (managed, `ProGPU.Wpf.Interop`). Effort: large; risk: highest of all items. Not needed to remove C++/CLI.

## 3. Packaging / CI consequences

| Once gone | Removable |
|---|---|
| DWF (A) | `.github/workflows/publish-librewpf-github-packages.yml` job `stage-windows-managed-runtime` (windows-2025, 90 min) and its artifact download in `publish`; `needs:` entry; `dist.local.sh` sections "Producing the per-RID Windows managed runtime payload" (~L775-830), `wpf_ijwhost_path`/`IjwHostSourcePath` (L120-130, 219, 389, 438), `CL=/MP1`, `VCTargetsPath`, VS 18 `MSBuild.exe` requirement and the single-node `run_wpf_msbuild` Windows branch (L160-225); `tools/CheckPayloadArch.cs` DWF exception; `LibreWPF/eng/progpu-wpf-windows-managed-runtime.ps1`; `runtimes/<rid>/lib/net10.0` entries and ijwhost packing in `Microsoft.DotNet.Wpf.GitHub.ArchNeutral.csproj`; the AGENTS.md "Windows lane" VS/C++ toolchain text. PresentationCore becomes AnyCPU, so the `LibreWpfArchNeutralTransportAssemblies` whitelist already covers it. |
| System.Printing (B) | PresentationUI vcxproj reference, "(with System.Printing)" build step, PCH memory workarounds (`UseSharedCompilation=false`, VBCSCompiler kill, `C1076`/`C3859` notes) |
| Stale WinForms reasoning | Dual canonical WFI feeds (`canonical-winforms-feed-x64`) and `patch-librewinforms-deps.ps1` x64/arm64 split: WFI is already AnyCPU, so one feed suffices **(unverified: confirm the LibreWinForms side has no arch-specific assembly)** |
| Native (C) | Nothing to remove from CI (not built); only cleanup of dead project refs and win-x86 audit entries |

After A+B the `windows-2025` compile job is not needed for managed assets; the Windows native ProGPU job (`stage-windows-native`) stays,
since that is Rust/CMake, not C++/CLI (though it still needs a Windows toolchain for `progpu_native.dll` and Direct2D; Visual Studio is
required there for the native renderer, not for WPF). So "no Visual Studio at all" requires also cross-building ProGPU natives
(e.g. clang-cl/xwin) — out of scope here.

## 4. Recommended order

1. **Quick win (days):** unconditional `System.Printing-ref` in PresentationUI; remove the System.Printing vcxproj from the Windows build and the PCH
   workarounds. Clean up stale WinForms dual-feed reasoning and dead native project refs / win-x86 audit entries. No behaviour change in what ships.
2. **Decision gate:** check how OpenDevelop on Windows runs today (MIL vs Portable media backend; DirectWrite vs portable text). If portable is
   acceptable, do A.1 for a fast single-binary PresentationCore.
3. **A.2/A.3 (weeks):** managed DirectWrite wrappers + `TtfDelta` port, with the portable path as fallback; then delete the Windows managed-runtime job and
   all ijwhost/VS plumbing.
4. **Optional/long term:** make Portable the Windows default and retire `wpfgfx`/`PenImc` dependencies (or keep consuming them from the Microsoft
   runtime package indefinitely — they cost nothing to build).

## 5. Open questions / unverified

* Whether the real C++/CLI `System.Printing.dll` ever reaches a published asset (script copies it as a "transitive assembly" into `artifacts/windows-managed-runtime`).
* Windows text/media backend actually used in OpenDevelop on Windows; DirectWrite parity requirements.
* Exact public API surface of DWF consumed by PresentationCore (33 files reference `TextInterface`; a type-by-type usage matrix was not produced).
* Whether `ReachFramework`/XPS serialization uses the DWF TrueType subsetter on Windows only.

## Addendum: follow-up questions

* **Can Windows use ProGPU.Text?** Code-wise yes: `PortableTextInterface.cs` already enumerates `%WINDIR%\Fonts` under
  `OperatingSystem.IsWindows()` (L475-477), and the `ProGPU.Text` sources are plain managed. What blocks it is only the
  compile-time `'$(OS)' == 'Windows_NT'` switch in `PresentationCore.csproj`. Not verified: that the portable text path has ever run on Windows.
* **Size of System.Printing:** C++ sources ~75.7k lines (headers included; DirectWriteForwarder ~23.1k). The public API (`ref/System.Printing.cs`
  + internals) is only ~870 lines. A managed equivalent over `winspool.drv` + PrintTicket XML is feasible but only the
  `PrintQueue` stub ships today, so there is no urgency.

## Addendum 2: community prior art (web search, 2026-11-26; shallow, verify before relying)

Decision taken: drop DirectWriteForwarder, invest in ProGPU.Text; ship a fully managed System.Printing.

Managed text shaping:
* SixLabors.Fonts - pure managed OpenType shaper (script shapers, USE scripts, GSUB; GPOS detail not confirmed). https://docs.sixlabors.com/articles/fonts/shaping.html
  Licence is Six Labors Split (not plain MIT) - check before reusing code.
* LayoutFarm/Typography - MIT, pure C# OpenFont reader + GSUB/GPOS GlyphLayout (README calls GlyphLayout "not stable"). https://github.com/LayoutFarm/Typography
* CosmoFonts claims pure-C# shapers (incl. SixLabors) lack pre-base/post-base reordering and conjunct clusters for Indic scripts - a third-party claim, unverified.
* Ports of HarfBuzz exist in Rust (harfrust/rustybuzz) and Go, not a complete managed port found. HarfBuzzSharp is only a native binding.
* Wine dlls/dwrite (LGPL C) is a reimplementation of the DirectWrite analyzer/layout API; useful as a behavioural reference, not reusable code.
=> Complex-script shaping (Indic/Arabic/USE) is the hard part; no turnkey managed answer. Options: extend ProGPU SfntSimpleGlyphShaper (port USE + Indic rules from the OpenType spec), or ship HarfBuzzSharp as an optional shaper.

Managed printing:
* PrintingTools (alpha, MIT, Avalonia) - adapters for Win32/XPS, macOS, Linux CUPS; shells out to CUPS tools. https://www.nuget.org/packages/PrintingTools
* SharpCUPS - managed IPP/1.1 client (talks to a CUPS server). https://www.nuget.org/packages/SharpCUPS
* Vanara.PInvoke.Printing - winspool.drv/prntvpt.dll P/Invoke wrappers (MIT). https://www.nuget.org/packages/Vanara.PInvoke.Printing
* Rust `printers` crate - design reference for cups+winspool.
=> No existing managed System.Printing clone. Suggested build: Windows via winspool/prntvpt P/Invoke (Vanara as reference or dependency), macOS/Linux via IPP (SharpCUPS-style) or libcups P/Invoke, PrintTicket as managed XML.

Not found: another open-source WPF port that replaced DirectWrite (Avalonia XPF is commercial and keeps WPF's own stack under a different renderer).

## Addendum 3: correction - ProGPU already has a full managed shaper

Earlier text called ProGPU's shaper "simple SFNT". That only describes what WPF's `PortableTextInterface` calls today
(`SfntSimpleGlyphShaper`, 182 lines). `external/ProGPU/src/ProGPU.Text` also contains `OpenTypeTextShaper.cs` (~9.4k lines, OpenFontSharp GSUB/GPOS,
feature settings, variations), Arabic joining/fallback, Indic/USE/Khmer/Myanmar syllable machines, Unicode bidi/line-break/normalization data and
`ProGPU.Text.Shaping`. The Avalonia lane already uses it as the default `ITextShaperImpl` and keeps HarfBuzz behind `--harfbuzz` as a differential oracle
(`docs/AVALONIA_COMPOSITOR_BACKEND_ARCHITECTURE.md` L17, L413).
Plan: wire `PortableTextInterface` to `OpenTypeTextShaper` (shape plans, clusters, features) instead of the simple shaper; reuse the Avalonia HarfBuzz differential
corpus for WPF; keep HarfBuzzSharp as test-only (or optional) rather than a dependency. Printing: read PrintingTools only for adapter design ideas.

## Status after implementation (2026-11-26)

Decision: drop DirectWriteForwarder (DWF), fill the gap in ProGPU; ship a managed `System.Printing` later.

Done (ProGPU commits `fe3b57704` and `460187a9d`, pushed to `origin/main` as `460187a9d`):
* The OpenType engine (`OpenTypeTextShaper`, `CpuOpenTypeShaper`, script/Unicode/Indic/USE/Khmer/Myanmar/Arabic data)
  moved from `ProGPU.Text` to the renderer-independent `ProGPU.Text.Shaping`, now over `IShapingFontFace`.
  `TtfFont` implements it directly; `TypeForwardedTo` keeps `ProGPU.Text` binary compatible.

Done (LibreWPF branch `claude/portable-text-opentype-shaper`, pushed; release pin `5ad647e34`):
* `PortableOpenTypeShaping` adapter + script-run `Itemize`; `TextAnalyzer` glyph APIs shape through the engine.
* `LibreWpfUseCppCli` (default `false`) gates DWF, `System.Printing.vcxproj` and the DirectWrite/portable
  compile switches in `PresentationCore.csproj`, so Windows and macOS/Linux now build the same assembly.
* Package: no per-RID `PresentationCore`/`DirectWriteForwarder`/`ijwhost`, no `runtimes/<rid>/lib`; the audit
  rejects them. The `windows-managed-runtime` jobs and `progpu-wpf-windows-managed-runtime.ps1` are gone.
* openavalon: `stage-windows-managed-runtime` job, the managed-runtime and ijwhost/VS/`CL` plumbing in
  `dist.local.sh`, and the DWF exception in `tools/CheckPayloadArch.cs` are removed.

Not done / not verifiable on this Mac:
* **Nothing was run on Windows.** Windows text now uses the portable stack (fonts from `%WINDIR%\Fonts` and the
  per-user fonts folder); font fallback/metrics/ClearType parity with DirectWrite is unmeasured. The Windows PowerShell
  smoke/showcase scripts were edited to expect no DWF/ijwhost but not run.
* `src/Microsoft.DotNet.Wpf/tests/UnitTests/Directory.Build.targets` still builds native vcxproj (wpfgfx etc.)
  for unit tests on Windows; left unchanged.
* The DWF and System.Printing sources are still in the tree (opt-in). Delete them only after a Windows run.
* Managed `System.Printing` (PrintingTools Win32/CUPS backends, Print Schema tickets, `XpsDocumentWriter`)
  is implemented under `src/Microsoft.DotNet.Wpf/src/System.Printing/managed` and is the shipped
  `System.Printing.dll` from `5ad647e34`; the C++/CLI project remains opt-in via `-p:LibreWpfUseCppCli=true`.
  See `doc/managed-system-printing-design.md`.
* Portable text gaps: no variable fonts and no cmap-14 variation selectors in `SfntFontFace`; vertical (sideways)
  text still uses the simple shaper; `GetGlyphPlacements` reshapes and falls back to simple advances when the glyph
  count differs.
* Dual canonical WinForms feeds in `dist.local.sh` are unchanged although `WindowsFormsIntegration` is AnyCPU C#.

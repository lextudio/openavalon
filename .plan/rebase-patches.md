# Rebase LibreWinForms + ProGPU patches to latest NuGet.org versions

## Current State

### LibreWinForms
- **Current base**: `librewinforms-v0.1.0-preview.42`
- **Target base**: `librewinforms-v0.1.0-preview.44` (latest on NuGet.org)
- **Patches to rebase** (2 commits):
  1. `ef32b32f6d Fix macOS font handling` — Wraps Win32 P/Invoke calls (`GetSystemDefaultLCID`, `GetStockObject`) in `OperatingSystem.IsWindows()` guard so `SystemFonts.DefaultFont` doesn't throw `EntryPointNotFoundException` on macOS/Linux.
  2. `d424ae3b78 Fix designer control preview` — Adds designer control preview functionality in `WindowsFormsHost.cs` and a smoke test in `LibreWinForms.SdkSmoke`.

### ProGPU
- **Current version**: `v0.1.0-preview.48`
- **Target version**: `v0.1.0-preview.54` (latest on NuGet.org)
- **Patches**: 0 — just update the submodule pointer.

## Execution Plan

### Step 1: Update ProGPU submodule to `v0.1.0-preview.54`
No patches, so this is a straightforward submodule pointer update:
```bash
cd LibreWPF/external/ProGPU
git checkout v0.1.0-preview.54
cd ../..
git add external/ProGPU
```

### Step 2: Rebase LibreWinForms patches (2 commits) onto `librewinforms-v0.1.0-preview.44`

For each patch, follow this process:
1. Create a temp test project that exercises the specific fix
2. Check if the upstream `preview.44` already contains the same fix
3. If already fixed upstream → **drop** the commit, move to next
4. If not fixed → cherry-pick onto `librewinforms-v0.1.0-preview.44` base, verify with temp test

#### Patch 1: `ef32b32f6d Fix macOS font handling`
- **What it does**: Guards Win32-only P/Invoke calls in `SystemFonts.cs` with `OperatingSystem.IsWindows()`
- **Test**: Build a WinForms app on macOS that accesses `SystemFonts.DefaultFont` — should not throw
- **Check upstream**: Compare `SystemFonts.cs` in `preview.44` vs `preview.42` to see if the `OperatingSystem.IsWindows()` guard was added upstream

#### Patch 2: `d424ae3b78 Fix designer control preview`
- **What it does**: Adds designer control preview in `WindowsFormsHost.cs` and smoke test
- **Test**: Build the `LibreWinForms.SdkSmoke` project and verify designer preview works
- **Check upstream**: Compare `WindowsFormsHost.cs` in `preview.44` vs `preview.42`

### Step 3: Update LibreWPF submodule pointer
After both submodules are updated, stage the changes in the parent LibreWPF repo and then in the openavalon root repo.

## Verification
- Each dropped commit must be confirmed as already-fixed in upstream
- Each cherry-picked commit must pass its temp test project
- Final build of the full solution should succeed

## Results (2026-08-23)

### LibreWinForms (done)
- `ef32b32f6d Fix macOS font handling`: **DROPPED** — ProGPU.System.Drawing.Common preview.54 fixes it upstream (`/tmp/test-font-fix`)
- `d424ae3b78 Fix designer control preview`: **KEPT** — cherry-picked as `82859dc874` (`/tmp/test-designer-preview`)

### ProGPU (done)
- Updated to `v0.1.0-preview.54`, no patches.

### LibreWPF (done)
- Branch `rebase-preview44` = `librewpf-v0.1.0-preview.44` + 26 source patches + submodule update (`90a9ac7e5`).
- All 28 original commits checked with `git merge-base --is-ancestor`: none in upstream preview.44.
- 4 conflicts resolved during cherry-pick (Popup.cs kept upstream's `UsesPortableLogicalScreenCoordinates`; ProGpuWpfWindowHost.cs merged DPI + transparency + dispatch-depth counter; WpfPortableWindowActivation.cs merged dispatcher dispatch + exception handler; host tests merged assertions).

### Crash reproduction tests vs upstream NuGet packages (`/tmp/test-crash-nuget`)
App: `LibreWPF.Sdk/0.1.0-preview.44`, TFM net10.0-windows, UseWindowsForms=true; run on macOS arm64 via reflection probes over all shipped assemblies.

| Patch | Result | Evidence |
|---|---|---|
| `89c67a917 Fix a macOS crash` | **CRASH REPRODUCED — keep** | `MS.Win32.UnsafeNativeMethods.GetWindowLongPtr/GetWindowLong`, `MS.Internal.WindowsBase.NativeMethodsSetLastError.GetWindowLong`, `MS.Internal.UIAutomationTypes.NativeMethodsSetLastError.GetWindowLong[Ptr]` all throw `DllNotFoundException` for `PresentationNative_cor3.dll` on macOS. Patch's guard covers the real call path (`GetWindowStyle` → `UnsafeNativeMethods.GetWindowLong`). Known gap: direct `NativeMethodsSetLastError.GetWindowLong*` calls remain unguarded. |
| `85adc68ad Fix macOS crashes` | **PARTIALLY redundant** | Font path (`SystemFonts.DefaultFont`, `Control()` ctor): NO crash with current package stack — ProGPU.System.Drawing.Common preview.54 fixed it. Shipped packages reference none of `GetSystemDefaultLCID`/`GetUserDefaultLCID`/LangID/`GetObjectA/W` anymore. BUT `System.Private.Windows.Core.dll` still P/Invokes `GetThreadLocale` (live: `IDispatch.SetPropertyValue`/`GetIDOfName`) and upstream Win32Compat.c lacks that export → keep at least `GetThreadLocale`. Drag-drop cursor feedback fix in same commit is unrelated to crashes and needed. Decision: keep whole commit (slimming saves nothing, risks regressions). |
| `6d1248081 native event dispatch reentrancy` | **NOT reproduced (needs interactive automation)** | Requires modal-dialog callback disposing a different host while its owner pumps GLFW events. Source-level check: upstream has no `s_activeNativeEventDispatchDepth` counter. Keep. |

Test A method note: type name searches must use UTF-8 (#Strings heap) not UTF-16LE (#US is only for ldstr literals); portable build merges partial classes so the guard lives in `MS.Win32.UnsafeNativeMethods` even though patch edits file `UnsafeNativeMethodsOther.cs`.

### Full CI verification of rebased branch (`eng/progpu-wpf-sdk-ci.sh`, run3 log `/tmp/sdk-ci-rebase44-run3.log`)
- ProGPU packages, managed transport build, themes, harnesses: all built and ran on macOS.
- Package audit + release bundle + SDK smokes (switch/mixed/external): succeeded after seeding `artifacts/windows-managed-runtime/{win-x86,win-x64,win-arm64}/{net10.0/{PresentationCore,DirectWriteForwarder}.dll,native/ijwhost.dll}` from the published LibreWPF.Transport nupkg (Windows payloads can only be produced by a Windows build; seeding is local-smoke only).
- HelloApp live validation: PASSED (Application.Run, live input incl. TextBox focus/typing/button click, live geometry).
- MvpApp: Application.Run validations passed; live input FAILED at menu popup step — `InvalidOperationException: Expected a visible native popup for MouseUp input`.
  - **Not a rebase regression**: verified via git worktree at pre-rebase commit `414f0135c` — same failure (`/tmp/mvp-live-oldbranch6.log`). Pre-existing on this machine/environment.
- SciChart/Toolkit/Xceed phases not reached in run3 (script exits at MvpApp failure).
- Worktree gotchas for reproducing: old branch global.json pins SDK 11.0.100-preview.5; symlink whole `.dotnet` dir from main repo into worktree, seed windows-managed-runtime, and unset stray DOTNET_ROOT.

### Branch state
- `openavalon` branch fast-forwarded to rebase-preview44 tip `90a9ac7e5` (diverged from origin; force-push pending user approval).

### MvpApp menu-popup failure root cause (investigated 2026-08-23)
Two compounding divergences broke `ValidateLiveMenuPopupSurfaceAsync` on macOS;
both fixed in LibreWPF `35dfa25d6` (MVP live input + geometry now pass, full CI green):

1. **Sample theme divergence** (`7b2802340` companion changes): MvpApp used
   `ThemeMode="System"` without the Fluent merged dictionary. The different
   MenuItem templates made the injected MouseDown land on a ButtonBase whose
   `CaptureMouse()` raised `MenuBase.OnLostMouseCapture` → menu mode exited →
   submenu closed before MouseUp ("Expected a visible native popup"). Restored
   upstream App.xaml/App.xaml.cs; removed FlatMenuChrome.
2. **Generous GetScreenBounds bound** (`ff644bb48`, multi-level popup position):
   placed the native menu popup at a negative-x origin inside the owner client,
   so owner-client diagnostic coordinates normalized to y<0 and every injected
   click was ignored by `TryProcessNativeInput`. Reverted to upstream
   owner-client placement + its graph-test assertions.

Also fixed stale graph tests (`37d2f0464`) that upstream refactors had left
unverified (CI only runs ProGpuWpfSdkProvidesSwitchOnlyPackagingSurface):
scheduler/invalidation entrypoints moved to ProGpuWpfWindowHost (#95),
ProGPU hit-test cache API renames (localThickness, hitTestTransform),
PresentationCore compile-item casing, GeneratePathProperty PackageReferences,
and restored MvpApp theme assertions.

Environment notes for local runs: unset DOTNET_ROOT (session leakage pointed
apphosts at /usr/local/share/dotnet which lacks the 11.0 preview runtime);
DOTNET_ROLL_FORWARD=Major needed for manual vstest; HelloApp text-edit flake
('HLiv' vs 'Liv') observed once, transient.

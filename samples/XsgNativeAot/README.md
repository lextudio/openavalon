# XSG + NativeAOT prototype

A LibreWPF app published with **NativeAOT** on macOS (osx-arm64): one native Mach-O executable, no JIT, no BAML, no System.Xaml
at run time. XAML is compiled by the LibreWPF XAML source generator (XSG), including the theme and the bindings.

**Package source.** `NuGet.config` takes the OpenAvalon packages (`LibreWPF.*`, `LibreWinForms.*`, `ProGPU.*`) from the OpenDevelop checkout
beside this repository: `../../../OpenDevelop/artifacts/openavalon-feed`, the folder OpenDevelop fills with `pwsh ./sync-openavalon-feed.ps1`.
It must contain `LibreWPF.Sdk` and the closure at the version `global.json` pins (`0.1.0-preview.69.61.1`). In any other layout `dotnet restore`
fails with NU1101 until you point the `openavalon` source in `NuGet.config` at a folder (or feed) that has those packages.

```bash
./prepare.sh                                   # build + patch the LibreWPF assemblies newer than the packages (see below)
dotnet publish -c Release                      # PublishAot=true, RuntimeIdentifier=osx-arm64 (see XsgAot.csproj)
bin/Release/net10.0-windows/osx-arm64/publish/XsgAot          # the window
bin/Release/net10.0-windows/osx-arm64/publish/XsgAot check    # self-check, prints PASS/FAIL and exits
```

`check` output on 2026-11-23 (Apple silicon, Xcode SDK via `SDKROOT`):

```text
nativeaot=True
ok   window template: Border > AdornerDecorator
ok   layout: 420x208
ok   button template: border=420x19.798828125 background=#FFDDDDDD
ok   binding source->target: greeting='Hello, Ada' name='Ada'
ok   binding INPC update: greeting='Hello, Grace' name='Grace'
ok   binding TwoWay target->source: vm.Name='Linus' greeting='Hello, Linus'
ok   binding is compiled: path='(0).(1)' parameters=2
PASS
```

## What makes it work

| Problem under NativeAOT | What failed | Fix |
|---|---|---|
| BAML themes | `Assembly.Load("PresentationFramework.Aero2")` has no metadata; rooting it drags the whole System.Xaml/BAML known-type graph in and fails (`XpsDocumentWriter` type load). Without a theme, `Window` has no template and lays out at 0x0. | `Theme/` is a theme **compiled by XSG** (`LibreWpfXsgResourceAssemblyName=PresentationFramework.Aero2`). Its module initializer registers it with `System.Windows.Markup.XamlSourceGeneratedResources`; `SystemResources` asks that registry by assembly name before it loads a theme assembly or BAML. |
| Theme registration never ran | ILC got the theme as a plain reference (`-r:`), so its module initializer was not part of the image. | `<TrimmerRootAssembly Include="XsgAot.Theme" />` in the app. |
| Reflective bindings | `PropertyPathWorker` resolves `{Binding A.B}` with reflection over the source type. | **Compiled bindings** (`LibreWpfCompiledBindings`, under `x:DataType`): each path step is a generated `PropertyDescriptor` with typed delegates, passed as an early-bound `PropertyPath` parameter; the stock binding engine needs no change. |
| Window creation | Silk.NET finds its GLFW platform by loading an assembly by name and `Activator.CreateInstance` ("Couldn't find a suitable window platform"). | `ProGpuWpfWindowHost` registers `GlfwWindowing`/`GlfwInput` explicitly before the first window. |
| SDK refuses | `NETSDK1168: WPF is not supported ... with trimming enabled`. | `_SuppressWpfTrimError=true`. |

## Prototype shortcuts (what is not product yet)

- `prepare.sh` patches `PresentationFramework` (ref + lib) and `ProGPU.Wpf` from a local LibreWPF build into this sample's private
  `packages/` folder (never the shared feed or NuGet cache); `./prepare.sh --restore` undoes it. Both changes ship with the next
  LibreWPF publish, after which `prepare.sh` is unnecessary.
- `XsgLocal.targets` uses the generator from the checkout and declares the compiler-visible switches the next SDK ships.
- `Theme/` covers only `Window` and `Button`. A full XSG build of `PresentationFramework.Aero2` (and the other in-box themes) needs
  generator coverage this prototype does not have yet (MultiTrigger/DataTrigger, storyboards, `Style.Resources`, …).
- The theme assembly must be rooted by hand; the SDK should root XSG theme assemblies automatically.
- Not verified here: pixels on screen (screen capture is not permitted from the build shell, and `RenderTargetBitmap` needs the
  Windows `wpfgfx` in JIT and AOT alike). Run the binary without `check` to look at it.
- ILC still reports trim/AOT analysis warnings (`IL3053`) for WindowsBase, PresentationCore, PresentationFramework, System.Xaml;
  paths this app does not use (XAML/BAML loading, `TextRange` serialization, …) were not exercised.

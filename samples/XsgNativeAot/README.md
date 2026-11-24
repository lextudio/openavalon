# XSG + NativeAOT prototype

A LibreWPF app published with **NativeAOT** on macOS (osx-arm64): one native Mach-O executable, no JIT, no BAML, no System.Xaml
at run time. XAML is compiled by the LibreWPF XAML source generator (XSG), including the bindings and **the real in-box Aero2 theme**
(`Theme/` links `Aero2.NormalColor.xaml` from the LibreWPF checkout; it is not a copy and not a hand-written stand-in).

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

`check` output on 2026-11-23 (Apple silicon, Xcode SDK via `SDKROOT`; the window is the sample's `MainWindow` with the real Aero2 theme):

```text
nativeaot=True
ok   window template: Border > AdornerDecorator
ok   layout: 420x608
ok   button template: border=420x17.798828125 background=#FFDDDDDD
ok   binding source->target: greeting='Hello, Ada' name='Ada'
ok   binding INPC update: greeting='Hello, Grace' name='Grace'
ok   binding TwoWay target->source: vm.Name='Linus' greeting='Hello, Linus'
ok   binding is compiled: path='(0).(1)' parameters=2
ok   template initializer: rows=2 height0=Auto
ok   startup uri: MainWindow is MainWindow
ok   merged dictionary: AccentBrush=#FF3366CC CardPadding=8,4,8,4
ok   user control: title='a user control, styled from App.xaml resources' background=#FFEEF3FB
ok   image resource: source=BitmapImage 48x48 element=48x48
ok   gallery: visuals=236 controlsWithoutTemplate=0 columnHeaders=2 listItems=3[alpha,beta,gamma] tableRows=3 gridRows=3 treeRoots=1
ok   dynamics: upper='ADA' joined='ada/0'->'ada/1' background=#FFD3D3D3->#FFFFD700 name='grace' tip='grace' items=3 stateManager=True
ok   generic theme: template=applied text='new' background=#FF3366CC radius=8
ok   generic theme trigger: disabled background=#FF808080
ok   frame navigation: content=Page1 title='page one' body='page body'
PASS
```

`./compare-jit-aot.sh` runs the same window (a UserControl from its own XAML plus Button, CheckBox, RadioButton, ComboBox, ListBox, Slider, ProgressBar,
ScrollBar, TabControl, a custom template) in the JIT build, which uses the in-box BAML Aero2, and in the NativeAOT build, which uses Aero2 compiled by XSG, and
diffs the visual trees (type and size of every element). Result: **134 elements in both, identical**, except that the outermost client-area height
is 612 in JIT and 608 in AOT (the native window frame; nothing inside the window differs).

**Pixels** (`./compare-pixels.sh`, screenshots in `screenshots/`): the same window rendered by the JIT build (BAML Aero2) and by the NativeAOT
build (Aero2 compiled by XSG). Aligned on the content (the title bars are not compared), **no pixel differs by more than 1/255 in any channel**
(in the last run all 924,000 compared pixels were exactly equal; an earlier run had about 0.4% of them one level apart, in the TextBox and
ListBox edge rows: the frame it caught); the contents are identical. The title bars differ because macOS draws the frame of a binary by the SDK it was linked with (the JIT
apphost: SDK 15.5, classic grey bar with a centred title; the NativeAOT executable: SDK 27.0, the new taller bar with the title on the left),
which is also the 4 pt (612 vs 608) of client height in the visual-tree diff above. Screenshots need an unlocked screen (a locked session is not composited and every capture is blank: `compare-pixels.sh` refuses to run then)
and are taken by the app itself
(`MacWindowCapture`, `XSGAOT_CAPTURE=<png>` with `check`): a process may capture its own windows without the Screen Recording permission;
`screencapture`, another process, and DevFlow's `/api/v1/ui/screenshot` (it goes through `RenderTargetBitmap`, which needs the Windows-only
`wpfgfx_cor3`) cannot.

DevFlow (`LeXtudio.DevFlow.Agent.LibreWpf` 0.3.1, tried here by adding the package and `AddWpfDevFlowAgent`; not kept in the sample): under JIT its
status, actions and tree work. Under NativeAOT its HTTP server starts but every request fails with "Reflection-based serialization has been disabled" (`System.Text.Json` without a
source-generated context): the agent itself is not NativeAOT-compatible yet.

The window is created by `App.xaml`'s `StartupUri`, `App.xaml` merges `Styles/Brushes.xaml` with `Source=`, and `Card.xaml` is a `UserControl` of
its own: the three things a real application has that a lone window does not. None of them can be loaded from a resource under NativeAOT; see
"Application, `StartupUri` and `Source`" in LibreWPF's `Documentation/XamlSourceGeneratorUsage.md`.

## What makes it work

| Problem under NativeAOT | What failed | Fix |
|---|---|---|
| BAML themes | `Assembly.Load("PresentationFramework.Aero2")` has no metadata; rooting it drags the whole System.Xaml/BAML known-type graph in and fails (`XpsDocumentWriter` type load). Without a theme, `Window` has no template and lays out at 0x0. | `Theme/` is a theme **compiled by XSG** (`LibreWpfXsgResourceAssemblyName=PresentationFramework.Aero2`). Its module initializer registers it with `System.Windows.Markup.XamlSourceGeneratedResources`; `SystemResources` asks that registry by assembly name before it loads a theme assembly or BAML. |
| Theme registration never ran | ILC got the theme as a plain reference (`-r:`), so its module initializer was not part of the image. | The SDK (`ProGPU.Wpf.Sdk.XamlSourceGeneratorNativeAot.targets`) roots every project reference when `PublishAot` and XSG are on; nothing in the app. |
| Reflective bindings | `PropertyPathWorker` resolves `{Binding A.B}` with reflection over the source type. | **Compiled bindings** (`LibreWpfCompiledBindings`, under `x:DataType`): each path step is a generated `PropertyDescriptor` with typed delegates, passed as an early-bound `PropertyPath` parameter; the stock binding engine needs no change. |
| Window creation | Silk.NET finds its GLFW platform by loading an assembly by name and `Activator.CreateInstance` ("Couldn't find a suitable window platform"). | `ProGpuWpfWindowHost` registers `GlfwWindowing`/`GlfwInput` explicitly before the first window. |
| SDK refuses | `NETSDK1168: WPF is not supported ... with trimming enabled`. | Lifted by the same SDK targets (it sets `_SuppressWpfTrimError` for XSG + `PublishAot`); nothing in the app. |
| Real Aero2 does not build as a theme | `UseWPF` references every in-box theme assembly, several define `SystemDropShadowChrome`. | The theme project keeps only the Aero2 reference (`KeepOnlyAero2Theme` target). |
| Document viewers cannot load | `System.Printing` is C++/CLI and Windows-only; its portable implementation has 1 of 56 public types. ILC replaces every method that needs `XpsDocumentWriter` (`DocumentViewerBase`, `FlowDocumentReader`, ...) with a throwing stub, including the theme's `InitializeComponent`. | Printing stays Windows-only: `LibreWpfXsgExcludeTargetTypes` (comma-separated: a `;` starts an .editorconfig comment) leaves the styles of `DocumentViewer`, `FlowDocument*`, `FixedDocument*` out of this theme. |
| Templates need more than `SetValue` | `FrameworkElementFactory` sets dependency properties only. | Three additive hooks: `SetInitializer` (fill a collection / set an object property after creation), `SetAttacher` (`Track.Thumb`, named `RowDefinition`s: the item is a real, named, targetable template node), `SetCreator` (`new T()` instead of `Activator.CreateInstance`). The content property written as an element (`<Border.Child>`) becomes an ordinary factory child. |
| `StartupUri`, `ResourceDictionary Source=`, `UserControl` | BAML resolves them at run time with `Application.LoadComponent` and pack URIs: no resource to read. | Each `x:Class` root object except the `Application` (a window, page or user control that can be created without arguments) is registered by resource path (`RegisterComponent`) and `LoadComponent(Uri)` asks that registry first; `Source` is resolved at build time to a registry lookup; `Uri` values are typed. |
| `<Image Source>` and other `Resource` items | The XSG path does not import `Microsoft.WinFX.targets`, so a `Resource` item is not embedded: nothing to read through `pack://application`. | `ProGPU.Wpf.Sdk.XamlSourceGeneratorResources.targets` (imported by `XsgLocal.targets` until the next SDK) writes `<AssemblyName>.g.resources` and embeds it; `ImageSource` text becomes `new BitmapImage(new Uri(...))`. |
| Binding paths `(Owner.Member)`, `(prefix:Owner.Member)` | The run-time path parser knows no prefix and resolves by reflection: `(base:AccessibilitySwitches.X)` throws and the binding silently does not apply. | Resolved at build time (a `DependencyProperty`, or a static `PropertyInfo`). Nine paths name `internal` types only the in-box theme assemblies can see: reported as `LWXSG0008`, and their `TypeNameParserException` is the two first-chance exceptions that remain. |
| Styles with triggers, converters, commands, VisualStateManager | Not a NativeAOT problem: a generator gap found by `Dynamics.xaml` (DataTrigger, MultiTrigger, EventTrigger + Storyboard, IValueConverter / IMultiValueConverter, MultiBinding, ICommand, a template with VisualStateGroups, ToolTip, ContextMenu, ItemsControl with ItemsPanel): `{StaticResource}` on `MultiBinding.Converter` had no cast, and `x:Name` on a `VisualState` was not its `Name`, so `GoToState` failed. | Fixed in the generator; the `dynamics` check is the same in JIT and NativeAOT. |
| A custom control with `Themes/Generic.xaml` | Nothing to fix: `Badge` (`DefaultStyleKey` + `ThemeInfo(None, SourceAssembly)`) finds its default style because the generator registers `Themes/Generic.xaml` under the assembly name like any loose dictionary; the template, TemplateBindings and a trigger work in JIT and NativeAOT (the `generic theme` checks). | Covered by `Badge.cs` and `Themes/Generic.xaml`. |
| `Frame.Source` / `NavigationService` to a generated page | Navigation reads a pack URI through a `PackWebRequest` and parses BAML; a generated `Page` has no resource (`IOException: Cannot locate resource`), JIT and NativeAOT alike. | `NavigationService.DoNavigate` asks the component registry first (the guard `Application.LoadComponent` uses: nothing registered, nothing changes); the `frame navigation` check covers it. |
| Missing `ListView` column headers | The Aero2 header row binds `TemplatedParent.View.Columns` by name (LWXSG0007: the template is applied by another template, so only the run-time type is known); NativeAOT had removed `ListView.View` / `GridView.Columns`, the headers were not created. | The SDK adds an rd.xml that keeps `ListView` and `GridView`. `Gallery.xaml` (Menu, ToolBar, TabControl, TreeView, ListView, DataGrid, Calendar, ...) is checked: its JIT and NativeAOT visual trees are identical (236 visuals). |
| `GridViewColumn` / `DataGridColumn` bindings, `DataGrid` new row | A binding in a column reads the row, not the root `x:DataType`; `DataGrid` offers its new-row placeholder only when it can construct the item type by reflection (JIT: 4 rows, AOT: 3). | `x:DataType="local:Row"` on each column; `CanUserAddRows="False"` for the same behaviour in both. |
| A DataTrigger's `Value="True"` | `DefaultValueConverter.GetConverter` goes through the BAML known-type table, which `Activator`-creates `BooleanConverter`. | Under NativeAOT only (`RuntimeFeature.IsDynamicCodeSupported` is false) it uses `TypeDescriptor`'s intrinsic converters first. |
| `StaticResource` of a key defined in a local `.Resources` | The key exists on the instance / style, not in the theme dictionary. | Looked up when applied (`SetResourceReference`, `DynamicResourceExtension`); `Style.Resources` / `ControlTemplate.Resources` / `Grid.Resources` are generated, and the generated dictionary keeps a scope stack for what is being built. |

## Prototype shortcuts (what is not product yet)

- `prepare.sh` patches `PresentationFramework` (ref + lib) and `ProGPU.Wpf` from a local LibreWPF build into this sample's private
  `packages/` folder (never the shared feed or NuGet cache); `./prepare.sh --restore` undoes it. Both changes ship with the next
  LibreWPF publish, after which `prepare.sh` is unnecessary.
- `XsgLocal.targets` uses the generator from the checkout and declares the compiler-visible switches the next SDK ships.
- `Theme/` builds the one theme that this window uses, Aero2, as a separate project that stands in for `PresentationFramework.Aero2` by
  name. The in-box theme assemblies themselves still carry BAML, and the other themes (Classic, Fluent, AeroLite, Luna, Royale) have not been
  run. The document viewers are left out of this theme on purpose (printing is Windows-only); each theme needs its own such list.
- Only project references are rooted automatically; an XSG theme shipped in a package must root itself (its own `TrimmerRootAssembly` item).
- ILC lists 13 more methods that "will always throw" in `ProGPU.Wpf`: members of PresentationCore it calls that do not exist there
  (`GlyphRun..ctor(TtfFont, ...)`, `GlyphRun.FontSize` / `GlyphIndices`, `DrawingContext..ctor(ProGPU.Scene.DrawingContext)`,
  `DashStyle..ctor(double[], double)`, `FontFamily.NativeFont`, `BitmapSource.GpuTexture`). Checked: this window draws all its text, borders,
  gradients and controls identically to the JIT build (the pixel comparison above), so none of them is on the path these controls take, including
  `ProGpuCompositionCommandSink.DrawGlyphRun`. The window's `<Image>` (a decoded PNG from `.g.resources`) is drawn and is part of the identical pixels, so `BitmapSource.GpuTexture` is not on the path an `Image` takes either. Not exercised by this window: dashed pens (`DashStyle`),
  drawing contexts created from ProGPU scenes, `FontFamily.NativeFont`; they stay open until something draws them.
- ILC still reports trim/AOT analysis warnings (`IL3053`) for WindowsBase, PresentationCore, PresentationFramework, System.Xaml;
  paths this app does not use (XAML/BAML loading, `TextRange` serialization, …) were not exercised.

# OpenAvalon

OpenAvalon publishes the coordinated LibreWPF, LibreWinForms, and ProGPU NuGet
package closure used by OpenDevelop and other preview consumers.

This is an integration and packaging repository. The framework source is pinned
through the `LibreWPF` submodule; OpenAvalon builds, verifies, and publishes one
version-aligned closure to lextudio GitHub Packages.

## Why XSG, NativeAOT, and F# matter

The closure is not only a version-alignment exercise. It carries three
framework capabilities that change what a WPF-style application can be.

### XAML Source Generator (XSG)

XSG compiles XAML into ordinary C# at build time instead of leaving it as BAML
for `System.Xaml` to load and reflect over at run time. That removes a large
reflection surface in a WPF application; under `x:DataType`, `{Binding}` paths
become typed accessors and a wrong path is a build error. It is also what makes
trimming and NativeAOT possible at all.

This is not a toy path. With `-p:LibreWpfXsgThemes=true`, the build compiles the
in-box theme dictionaries (Aero2, Aero, AeroLite, Classic, Royale, Luna, and
Fluent) for equivalence testing, and a harness compares each generated
dictionary with its BAML original; for Aero2 that is 376 keys compared, 4
explained differences, 0 unexplained. The shipped theme assemblies still use the
BAML compiler. `samples/XsgMixed` proves that XSG-compiled and BAML-compiled
assemblies interoperate in one solution (49 cases, both directions).

BAML remains the default. Opt in per project:

```xml
<PropertyGroup>
  <UseLibreWpfXamlSourceGenerator>true</UseLibreWpfXamlSourceGenerator>
</PropertyGroup>
```

See the [XSG usage guide](LibreWPF/Documentation/XamlSourceGeneratorUsage.md)
and [samples/XsgMixed](samples/XsgMixed/README.md).

### NativeAOT

[samples/XsgNativeAot](samples/XsgNativeAot/README.md) publishes a WPF-style
window as one native Mach-O executable on macOS arm64: no JIT, no BAML, and no
`System.Xaml` at run time.
Its 20 self-checks cover window and template creation, compiled bindings (source
to target, INPC updates, TwoWay), `StartupUri`, `ResourceDictionary Source`, a
`UserControl`, a custom `Themes/Generic.xaml`, `Frame` navigation, and the real
in-box Aero2 theme. The JIT and NativeAOT builds produce the same 135-element
visual tree (only the native window frame differs) and, in the last measured
run, pixel-identical window content. That is the difference between "a WPF app
that starts a JIT" and a self-contained native application that keeps WPF's
programming model.

Boundaries: the working prototype target is macOS arm64. Windows and Linux
NativeAOT are still planned; `XamlReader`/loose BAML, WinForms interop, and
printing/XPS stay outside the AOT subset. See
[LibreWPF's NativeAOT plan](LibreWPF/Documentation/NativeAotPlan.md).

### F#

F# has neither source generators nor partial classes, which used to make the
compile-time XAML path unavailable to it. `LibreWPF.Xaml.FSharp.Tool` (shipped in
the SDK under `tools/xsg-fsharp`) runs the same XSG over the project's reference
compilation, prints the generated object graph as F#, and the SDK compiles the
`.g.fs` files ahead of the project's own sources. Each `x:Class` becomes an F#
class that inherits the root element, declares its `x:Name` fields, and builds
the tree in its constructor. `PortableBootstrap.fs` replaces the C# module
initializer, and `[<XsgComponent>]` registers resource paths.

Enable it in a `.fsproj` with the same
`UseLibreWpfXamlSourceGenerator=true`. C# expressions in XAML are not part of
the F# output; event handlers named in XAML are resolved by name on the run-time
type, so write them in a subclass. Because it is the same XSG pipeline, F# gets
the same trimming and NativeAOT direction, not a separate reflective shortcut.

These are preview features, not a claim that every WPF application is ready for
NativeAOT today. They are why this closure is more than a rebuild of upstream
WPF: the XAML, theme, binding, and language pipelines are moving from run-time
reflection to compile-time code, and the samples and equivalence gates in this
repository are the evidence.

## What's published

The closure includes:

- `LibreWPF.Sdk`, `LibreWPF.Transport`, `LibreWPF.ProGPU`, and
  `LibreWPF.Interop`;
- LibreWinForms compatibility packages;
- ProGPU managed, native, text, media, and rendering packages; and
- the mobile host packages `ProGPU.Android`, `ProGPU.iOS`,
  `ProGPU.Android.Media`, and `ProGPU.Apple.Media`.

All packages are preview software. A successful publication proves that the
coordinated closure built, was packaged, and passed its release gates. It does
not promise source compatibility for every WPF application or full maturity of
every native graphics, accessibility, printing, NativeAOT, or mobile-rendering
path.

## Consuming the closure

Packages are published under the `lextudio` GitHub organization:

```xml
<add key="lextudio_github"
     value="https://nuget.pkg.github.com/lextudio/index.json" />
```

Use one aligned preview version for the SDK and the ProGPU closure; do not mix
versions from separate publications.

OpenDevelop CI restores from GitHub Packages. For local OpenDevelop work, use
its synchronized project-local feed instead of adding a GitHub token to NuGet
configuration:

```powershell
pwsh ./sync-openavalon-feed.ps1
```

See OpenDevelop's `AGENTS.md` for consumer pinning, authentication, and local
feed rules.

## Repository layout

| Path | Purpose |
| --- | --- |
| `LibreWPF/` | Pinned LibreWPF, LibreWinForms, and ProGPU source graph. |
| `dist.local.sh` | Canonical closure build run by the publication workflow. |
| `.github/workflows/publish-librewpf-github-packages.yml` | Serialized build, verification, and GitHub Packages publication workflow. |
| `dev-overlay.sh` | Temporarily overlays one locally built assembly into an OpenDevelop output. |
| `dev-patch-feed.sh` | Temporarily patches one assembly in OpenDevelop's local package feed. |

## Publishing

Pushes to `main` that change the source graph or publication workflow start the
publication workflow. It builds Windows, Linux, macOS, Android, and iOS native
inputs; packages and verifies the closure; then publishes it to GitHub Packages.

Publication is serialized and normally takes 1.5–2 hours. Do not use a local
feed-to-feed copy or a workstation `dist.local.sh` run as a substitute for a
consumer release. The workflow is the authoritative publication path.

## Developing a LibreWPF change

1. Make and verify the source change in `LibreWPF/`.
2. Commit the updated submodule pointer and any packaging changes here.
3. Push to `main` and wait for the publication workflow to succeed.
4. Move the consumer's aligned version pins and closure receipt to that publish.
5. Synchronize the consumer-local feed and run its relevant tests.

For a short-lived OpenDevelop experiment, use `dev-overlay.sh` or
`dev-patch-feed.sh`. Never hand-copy assemblies: a consumer rebuild or restore
would erase the change and can conceal a mismatched package closure.

## Support boundaries and further reading

Read [LibreWPF's README](LibreWPF/README.md) for framework goals, supported
scenarios, migration guidance, and package details. Read [AGENTS.md](AGENTS.md)
before changing versions, native inputs, submodule pins, or publishing logic.

The closure is intentionally version-aligned. A package, SDK, or consumer pin
must not advance independently of its matching publication.

## License and security

License and security information for the framework source is maintained in the
[`LibreWPF` submodule](LibreWPF/).

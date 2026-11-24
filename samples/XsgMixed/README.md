# XsgMixed: XSG-compiled and BAML-compiled assemblies in one solution

Checks that assemblies compiled by the LibreWPF XAML source generator (XSG) and by the stock BAML pipeline work together in both directions.
Two libraries have identical content and differ only in how they are compiled (`LibX` with XSG, `LibB` with BAML); two applications do the same
(`AppXsg`, `AppBaml`) and each uses both libraries.

What is checked, per library and per application (49 cases): `ResourceDictionary Source` in XAML and in code (relative, `pack://`, versioned, upper/lower case),
dictionaries merging each other's dictionaries across the compile modes, `x:Class` dictionaries (merged as an element and loaded through `Source`, with
`StaticResource` inside and `x:Shared="False"`), entries that stay lazy through `Source`, templates with triggers, converters, `ComponentResourceKey`,
relative `Sub/` merges, resources added at run time, UserControls whose own resources merge the other mode's dictionary, `Themes/Generic.xaml`,
implicit styles and data templates, `Application.LoadComponent` and `Frame` navigation to pages of both kinds, `XamlReader.Parse`, and a key/type
comparison of the same dictionary loaded from the XSG and the BAML library.

```bash
# Once, and after changing LibreWPF's PresentationFramework: build it and patch it into the private package folder this sample shares with XsgNativeAot.
../XsgNativeAot/prepare.sh

./gen.sh                      # generates LibX, LibB, AppXsg, AppBaml from tpl/ (the generated folders are not committed)
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
dotnet build AppXsg/AppXsg.csproj -c Release
dotnet build AppBaml/AppBaml.csproj -c Release
./AppXsg/bin/Release/net10.0-windows/AppXsg      # prints one ok/FAIL line per case
./AppBaml/bin/Release/net10.0-windows/AppBaml
MIX_TOUCH=1 ./AppXsg/bin/Release/net10.0-windows/AppXsg   # runs both libraries' module initializers first
```

The applications show windows (templates and layout need a presentation source), so run them on a machine with a display. Edit the templates under `tpl/`
(`@P@` is the library prefix `X`/`B`, `@NS@` its namespace, `@MODE@` the application mode) and rerun `gen.sh`.

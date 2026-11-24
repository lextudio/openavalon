using System.Windows;
using System.Windows.Markup;
using ThemeEquivalence;

// Compares an in-box BAML theme dictionary with the one compiled by the XAML source generator.
//   ThemeEquivalence [limit] [--theme=Aero2] [--files=aero2.normalcolor] [--time] [--probe-key=<key>] [path/to/PresentationFramework.<Theme>.dll]
//   (--time needs the dll path: it prints the first and later load time of the BAML and the generated dictionary)
// Without a dll path the sample's own Theme project (Aero2) is the XSG side; with one, that assembly (built with -p:LibreWpfXsgThemes=true in LibreWPF's own
// build) is loaded in its own load context. Prints at most `limit` unexplained differences; exit code 1 when there is one, when too few keys were compared,
// or when a documented known difference does not occur as often as documented.
[STAThread]
static int Run(string[] args)
{
    var limit = args.Select(x => int.TryParse(x, out var n) ? (int?)n : null).FirstOrDefault(x => x is not null) ?? 60;
    var theme = args.FirstOrDefault(a => a.StartsWith("--theme=", StringComparison.Ordinal))?["--theme=".Length..] ?? "Aero2";
    var files = (args.FirstOrDefault(a => a.StartsWith("--files=", StringComparison.Ordinal))?["--files=".Length..]
        ?? theme switch { "Classic" => "classic", "Fluent" => "fluent", _ => theme.ToLowerInvariant() + ".normalcolor" }).Split(',');
    var assemblyName = "PresentationFramework." + theme;
    _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };

    if (args.Contains("--menu-role"))
    {
        // A hand-written FrameworkElementFactory Menu > MenuItem (what the generator emits) vs the same through XamlReader (what BAML does).
        var menu = new FrameworkElementFactory(typeof(System.Windows.Controls.Menu));
        menu.AppendChild(new FrameworkElementFactory(typeof(System.Windows.Controls.MenuItem)));
        var template = new System.Windows.Controls.ControlTemplate(typeof(System.Windows.Controls.Control)) { VisualTree = menu };
        template.Seal();
        var root = (System.Windows.Controls.Menu)template.LoadContent();
        var item = (System.Windows.Controls.MenuItem)root.Items[0]!;
        var parsed = (System.Windows.Controls.Menu)XamlReader.Parse("<Menu xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><MenuItem/></Menu>");
        var parsedItem = (System.Windows.Controls.MenuItem)parsed.Items[0]!;
        var plain = new System.Windows.Controls.Menu();
        plain.Items.Add(new System.Windows.Controls.MenuItem());
        var viaInitializer = new FrameworkElementFactory(typeof(System.Windows.Controls.Menu));
        viaInitializer.SetInitializer(o => ((System.Windows.Controls.Menu)o).Items.Add(new System.Windows.Controls.MenuItem()));
        var template2 = new System.Windows.Controls.ControlTemplate(typeof(System.Windows.Controls.Control)) { VisualTree = viaInitializer };
        template2.Seal();
        var root2 = (System.Windows.Controls.Menu)template2.LoadContent();
        var withAttacher = new FrameworkElementFactory(typeof(System.Windows.Controls.Menu));
        var attached = new FrameworkElementFactory(typeof(System.Windows.Controls.MenuItem));
        attached.SetAttacher((p, c) => ((System.Windows.Controls.ItemsControl)p).Items.Add(c));
        withAttacher.AppendChild(attached);
        var template3 = new System.Windows.Controls.ControlTemplate(typeof(System.Windows.Controls.Control)) { VisualTree = withAttacher };
        template3.Seal();
        var root3 = (System.Windows.Controls.Menu)template3.LoadContent();
        Console.WriteLine($"FEF + SetAttacher(Items.Add): Role={((System.Windows.Controls.MenuItem)root3.Items[0]!).Role}");
        Console.WriteLine($"plain Items.Add: Role={((System.Windows.Controls.MenuItem)plain.Items[0]!).Role}; FEF + SetInitializer(Items.Add): Role={((System.Windows.Controls.MenuItem)root2.Items[0]!).Role}");
        Console.WriteLine($"FEF: Role={item.Role} logicalParent={LogicalTreeHelper.GetParent(item)?.GetType().Name}; XamlReader: Role={parsedItem.Role} logicalParent={LogicalTreeHelper.GetParent(parsedItem)?.GetType().Name}");
        return 0;
    }

    if (args.FirstOrDefault(x => x.StartsWith("--probe-key=", StringComparison.Ordinal)) is { } probe)
    {
        var key = probe["--probe-key=".Length..];
        foreach (var file in files)
        {
            var dictionary = new ResourceDictionary { Source = new Uri($"pack://application:,,,/{assemblyName};component/themes/{file}.xaml") };
            object? value = null;
            string how;
            try { value = dictionary[key]; how = "ok"; } catch (Exception e) { how = e.GetType().Name + ": " + e.Message; }
            Console.WriteLine($"{file}: [{key}] -> {value?.GetType().Name} {value} ({how}); merged={dictionary.MergedDictionaries.Count}");
        }
        return 0;
    }

    if (args.Contains("--time"))
    {
        // How long building the whole dictionary takes: BAML (a ResourceDictionary with Source, its templates are parsed lazily) vs the generated one (everything is built at once).
        var file = files[0];
        var uri = new Uri($"pack://application:,,,/{assemblyName};component/themes/{file}.xaml");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var cold = new ResourceDictionary { Source = uri };
        var bamlCold = sw.Elapsed.TotalMilliseconds;
        var bamlWarm = Enumerable.Range(0, 5).Select(i => { var t = System.Diagnostics.Stopwatch.StartNew(); var d = new ResourceDictionary { Source = uri }; return t.Elapsed.TotalMilliseconds; }).Average();
        var xsgPath = args.FirstOrDefault(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
        if (xsgPath is null)
        {
            Console.WriteLine("--time needs the path of the XSG-compiled PresentationFramework.<Theme>.dll.");
            return 2;
        }
        var ctx = new System.Runtime.Loader.AssemblyLoadContext("xsg-time");
        var asm = ctx.LoadFromAssemblyPath(System.IO.Path.GetFullPath(xsgPath));
        System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(asm.ManifestModule.ModuleHandle);
        sw.Restart();
        if (!XamlSourceGeneratedResources.TryCreateDictionary(assemblyName, $"themes/{file}.xaml", out ResourceDictionary? first))
        {
            Console.WriteLine($"The generated {assemblyName} themes/{file}.xaml is not registered.");
            return 2;
        }
        var xsgCold = sw.Elapsed.TotalMilliseconds;
        var xsgWarm = Enumerable.Range(0, 5).Select(i => { var t = System.Diagnostics.Stopwatch.StartNew(); XamlSourceGeneratedResources.TryCreateDictionary(assemblyName, $"themes/{file}.xaml", out ResourceDictionary? next); return t.Elapsed.TotalMilliseconds; }).Average();
        Console.WriteLine($"{assemblyName} {file}: BAML first {bamlCold:F0} ms, then {bamlWarm:F0} ms; XSG first {xsgCold:F0} ms, then {xsgWarm:F0} ms");
        return 0;
    }

    // The BAML dictionaries first: once a second assembly of the same name is loaded the name no longer resolves to the packaged one.
    var bamls = files.ToDictionary(f => f, f => new ResourceDictionary { Source = new Uri($"pack://application:,,,/{assemblyName};component/themes/{f}.xaml") });

    var xsgAssemblyPath = args.FirstOrDefault(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
    if (xsgAssemblyPath is not null)
    {
        var context = new System.Runtime.Loader.AssemblyLoadContext("xsg-" + theme);
        var assembly = context.LoadFromAssemblyPath(System.IO.Path.GetFullPath(xsgAssemblyPath));
        Console.WriteLine("XSG side: " + assembly.Location + " (" + new System.IO.FileInfo(assembly.Location).Length + " bytes)");
        System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(assembly.ManifestModule.ModuleHandle);
    }
    else
    {
        System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(typeof(XsgAot.Theme.Marker).Module.ModuleHandle);
    }

    // Differences that are understood and accepted, per theme (each with its cause); anything else fails the run.
    var known = new (string Pattern, int Count, string Why)[]
    {
        (@"/Menu\[\d+\]/MenuItem\[\d+\]\.MenuItem\.Role: MenuItemRole TopLevelItem vs MenuItemRole SubmenuItem$", theme == "Fluent" ? 6 : 4,
            "A MenuItem created as a FrameworkElementFactory node has no LogicalParent (UpdateRole needs 'LogicalParent is Menu'); BAML creates plain objects. Stock WPF behaviour of FEF templates; only the NavigationWindow chrome menu is affected."),
    };

    var total = 0;
    var failed = false;
    foreach (var file in files)
    {
        if (!XamlSourceGeneratedResources.TryCreateDictionary(assemblyName, $"themes/{file}.xaml", out var xsg))
        {
            Console.WriteLine($"The generated {assemblyName} themes/{file}.xaml is not registered.");
            return 2;
        }

        var differ = new Differ { ExcludedTypes = new HashSet<string> { "DocumentViewer", "FlowDocumentReader", "FlowDocumentScrollViewer", "FlowDocumentPageViewer", "FlowDocument", "FixedDocument", "FixedDocumentSequence" } };
        differ.CompareDictionaries(bamls[file], xsg);
        var unknown = differ.Diffs.Where(d => !known.Any(k => System.Text.RegularExpressions.Regex.IsMatch(d, k.Pattern))).ToList();
        var problems = new List<string>();
        if (differ.KeysCompared < 0.9 * differ.BamlKeys || differ.KeysCompared == 0) problems.Add($"only {differ.KeysCompared} of {differ.BamlKeys} keys were compared");
        foreach (var (pattern, expected, _) in known)
        {
            var seen = differ.Diffs.Count(d => System.Text.RegularExpressions.Regex.IsMatch(d, pattern));
            if (seen != expected) problems.Add($"known difference {pattern} occurs {seen} times, documented {expected}");
        }

        Console.WriteLine($"== {assemblyName} {file}: {differ.KeysCompared} of {differ.BamlKeys} keys compared, {differ.Diffs.Count} differences ({unknown.Count} unexplained), {differ.Excluded.Count} left out on purpose, {differ.Failed.Count} not instantiable on either side");
        foreach (var diff in unknown.Take(limit)) Console.WriteLine(diff);
        foreach (var problem in problems) Console.WriteLine("PROBLEM: " + problem);
        foreach (var (pattern, _, why) in known)
        {
            var count = differ.Diffs.Count(d => System.Text.RegularExpressions.Regex.IsMatch(d, pattern));
            if (count > 0) Console.WriteLine($"known difference x{count}: {why}");
        }
        total += unknown.Count;
        failed |= unknown.Count > 0 || problems.Count > 0;
    }

    Console.WriteLine(failed ? "NOT EQUIVALENT" : "EQUIVALENT (known differences only)");
    return failed ? 1 : 0;
}

return Run(args);

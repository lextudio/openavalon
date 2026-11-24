using System.Windows;
using System.Windows.Markup;
using ThemeEquivalence;

// Compares the in-box BAML Aero2 dictionary with the one compiled by the XAML source generator.
// Usage: ThemeEquivalence [limit]   (prints at most `limit` differences, default 60; exit code 1 when there are any)
[STAThread]
static int Run(string[] args)
{
    var limit = args.Length > 0 && int.TryParse(args[0], out var n) ? n : 60;
    _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };

    // The generated dictionary: registered under Aero2's name by the theme assembly's module initializer (touch its assembly first).
    System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(typeof(XsgAot.Theme.Marker).Module.ModuleHandle);
    if (!XamlSourceGeneratedResources.TryCreateDictionary("PresentationFramework.Aero2", "themes/aero2.normalcolor.xaml", out var xsg))
    {
        Console.WriteLine("The generated Aero2 dictionary is not registered.");
        return 2;
    }

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

    var baml = new ResourceDictionary { Source = new Uri("pack://application:,,,/PresentationFramework.Aero2;component/themes/aero2.normalcolor.xaml") };
    var differ = new Differ { ExcludedTypes = new HashSet<string> { "DocumentViewer", "FlowDocumentReader", "FlowDocumentScrollViewer", "FlowDocumentPageViewer", "FlowDocument", "FixedDocument", "FixedDocumentSequence" } };
    differ.CompareDictionaries(baml, xsg);
    // Differences that are understood and accepted (each with its cause); anything else fails the run.
    var known = new (string Pattern, int Count, string Why)[]
    {
        (@"/Menu\[\d+\]/MenuItem\[\d+\]\.MenuItem\.Role: MenuItemRole TopLevelItem vs MenuItemRole SubmenuItem$", 4,
            "A MenuItem created as a FrameworkElementFactory node has no LogicalParent (UpdateRole needs 'LogicalParent is Menu'); BAML creates plain objects. Stock WPF behaviour of FEF templates; only the NavigationWindow chrome menu is affected."),
    };
    var unknown = differ.Diffs.Where(d => !known.Any(k => System.Text.RegularExpressions.Regex.IsMatch(d, k.Pattern))).ToList();
    // The run must have compared something, and a known difference must occur exactly as often as documented (a new one at another place is news).
    var problems = new List<string>();
    if (differ.KeysCompared < 300) problems.Add($"only {differ.KeysCompared} keys were compared (expected about 375)");
    foreach (var (pattern, expected, _) in known)
    {
        var seen = differ.Diffs.Count(d => System.Text.RegularExpressions.Regex.IsMatch(d, pattern));
        if (seen != expected) problems.Add($"known difference {pattern} occurs {seen} times, documented {expected}");
    }
    foreach (var problem in problems) Console.WriteLine("PROBLEM: " + problem);
    foreach (var diff in unknown.Take(limit)) Console.WriteLine(diff);
    foreach (var (pattern, _, why) in known)
    {
        var count = differ.Diffs.Count(d => System.Text.RegularExpressions.Regex.IsMatch(d, pattern));
        if (count > 0) Console.WriteLine($"known difference x{count}: {why}");
    }
    Console.WriteLine($"left out on purpose (LibreWpfXsgExcludeTargetTypes): {differ.Excluded.Count}");
    Console.WriteLine($"keys compared: {differ.KeysCompared}, differences: {differ.Diffs.Count} ({unknown.Count} unexplained)");
    return unknown.Count == 0 && problems.Count == 0 ? 0 : 1;
}

return Run(args);

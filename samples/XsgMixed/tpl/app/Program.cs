using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using LibB;
using LibX;

namespace App@MODE@;

public static class Program
{
    static void Check(string name, Func<bool> test)
    {
        string result, detail = "";
        try { result = test() ? "ok  " : "FAIL"; } catch (Exception e) { result = "FAIL"; var i = e; while (i.InnerException != null) i = i.InnerException; detail = " -> " + i.GetType().Name + ": " + i.Message.Split('\n')[0]; }
        Console.WriteLine($"{result} {name}{detail}");
    }
    static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
    static Color C(object? o) => o is SolidColorBrush s ? s.Color : Colors.Transparent;

    static ResourceDictionary Dict(string p)
    {
        var path = $"/Lib{p};component/{p}Dict.xaml";
        try { return new ResourceDictionary { Source = new Uri(path, UriKind.Relative) }; }
        catch when (System.Windows.Markup.XamlSourceGeneratedResources.TryCreateDictionary($"Lib{p}", $"{p}dict.xaml", out var d)) { return d; }
    }

    static void Pump(Window w) { w.Show(); w.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle); }

    [STAThread]
    public static int Main()
    {
        // MIX_TOUCH=1: run both libraries' module initializers first (what the first use of any of their types does).
        if (Environment.GetEnvironmentVariable("MIX_TOUCH") == "1")
        {
            System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(typeof(XItem).Module.ModuleHandle);
            System.Runtime.CompilerServices.RuntimeHelpers.RunModuleConstructor(typeof(BItem).Module.ModuleHandle);
        }
        var app = new App();
        Console.WriteLine($"consumer=@MODE@ touch={Environment.GetEnvironmentVariable("MIX_TOUCH") ?? "0"}");
        foreach (var (p, lib) in new[] { ("X", "LibX(XSG)"), ("B", "LibB(BAML)") })
        {
            Check($"[{lib}] consumer XAML: Source=/{p}Dict.xaml in Window.Resources (+ StaticResource style/string, DynamicResource brush)", () =>
            {
                Window w = p == "X" ? new WinDictX() : new WinDictB();
                var b = (Button)w.FindName("Styled")!; var t = (TextBlock)w.FindName("Dyn")!;
                return (string)b.Tag == p && C(b.Background) == Rgb(0x11, 0x22, 0x33) && t.Text == "hello-" + p && C(t.Foreground) == Rgb(0x11, 0x22, 0x33);
            });
            Check($"[{lib}] consumer XAML: <l:{p}ClassDict/> (x:Class dictionary) as merged element", () =>
            {
                Window w = p == "X" ? new WinClassX() : new WinClassB();
                return C(((TextBlock)w.FindName("ClassBrush")!).Foreground) == Rgb(0x77, 0x88, 0x99);
            });
            Check($"[{lib}] consumer XAML: UserControl + custom control (Generic.xaml) + implicit style/DataTemplate not merged", () =>
            {
                Window w = p == "X" ? new WinCtlX() : new WinCtlB();
                var ctl = (FrameworkElement)w.FindName("Ctl")!;
                var custom = (Control)w.FindName("Custom")!; custom.ApplyTemplate();
                return ((TextBlock)ctl.FindName("Label")!).Text == p + " control" && custom.Template?.FindName("PART_Text", custom) is TextBlock tb && tb.Text == "generic-" + p;
            });
            Check($"[{lib}] x:Class dictionary: StaticResource inside it, and x:Shared=False gives a new instance per lookup", () =>
            {
                Window w = p == "X" ? new WinClassX() : new WinClassB();
                return C(((Border)w.FindName("Styled")!).Background) == Rgb(0x77, 0x88, 0x99)
                    && C(((Border)w.FindName("Sh1")!).Background) == Rgb(0x33, 0x44, 0x55)
                    && !ReferenceEquals(((Border)w.FindName("Sh1")!).Background, ((Border)w.FindName("Sh2")!).Background);
            });
            Check($"[{lib}] code: new ResourceDictionary {{ Source = /{p}Dict.xaml }}", () => new ResourceDictionary { Source = new Uri($"/Lib{p};component/{p}Dict.xaml", UriKind.Relative) }.Contains(p + "Brush"));
            Check($"[{lib}] code: Source = pack://application:,,,/Lib{p};component/{p}Dict.xaml", () => new ResourceDictionary { Source = new Uri($"pack://application:,,,/Lib{p};component/{p}Dict.xaml") }.Contains(p + "Brush"));
            Check($"[{lib}] code: Application.LoadComponent(/{p}Page.xaml)", () => ((TextBlock)((Page)Application.LoadComponent(new Uri($"/Lib{p};component/{p}Page.xaml", UriKind.Relative))).Content).Text == "page-" + p);
            if (p == "X") Check($"[{lib}] registry API directly: TryCreateDictionary(LibX, xdict.xaml)", () => System.Windows.Markup.XamlSourceGeneratedResources.TryCreateDictionary("LibX", "xdict.xaml", out _));
            Check($"[{lib}] (setup) merge {p}Dict into app resources via Source, else registry", () => { app.Resources.MergedDictionaries.Add(Dict(p)); return true; });
            Check($"[{lib}] code: UserControl {p}Control: own tree, own Local resource, DynamicResource to a dict merged into app resources", () =>
            {
                FrameworkElement c = p == "X" ? new XControl() : new BControl();
                c.Measure(new Size(100, 100));
                return C(((Border)c.FindName("Root")!).Background) == Rgb(255, 0, 0) && C(((TextBlock)c.FindName("Label")!).Foreground) == Rgb(0x11, 0x22, 0x33);
            });
            Check($"[{lib}] code: {p}Cross.xaml (lib dictionary that merges BOTH libs by pack URI)", () =>
            {
                var d = new ResourceDictionary { Source = new Uri($"/Lib{p};component/{p}Cross.xaml", UriKind.Relative) };
                return d.Contains(p + "CrossBrush") && d["XBrush"] != null && d["BBrush"] != null;
            });
            Check($"[{lib}] XamlReader.Parse mixing libs", () =>
            {
                var xaml = $"<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:l='clr-namespace:Lib{p};assembly=Lib{p}'><l:{p}Control/></StackPanel>";
                return ((StackPanel)XamlReader.Parse(xaml)).Children.Count == 1;
            });
            Check($"[{lib}] shown window: templated button (BasedOn style + ControlTemplate + TemplateBinding + StaticResource inside template)", () =>
            {
                Window w = p == "X" ? new WinRichX() : new WinRichB(); Pump(w);
                var b = (Button)w.FindName("Templated")!; b.ApplyTemplate();
                var border = (Border)b.Template.FindName("B", b);
                var ok = border.Padding == new Thickness(1, 2, 3, 4) && C(border.Background) == Rgb(0x11, 0x22, 0x33) && (string)b.Tag == p;
                var d = (Button)w.FindName("Disabled")!; d.ApplyTemplate(); var db = (Border)d.Template.FindName("B", d);
                w.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
                ok &= db.Opacity == 0.5; w.Close(); return ok;
            });
            Check($"[{lib}] shown window: converter binding, x:Int32, Thickness, ComponentResourceKey, relative Sub/ merge, x:Shared=False", () =>
            {
                Window w = p == "X" ? new WinRichX() : new WinRichB(); Pump(w);
                var parts = new (string, Func<bool>)[] {
                    ("converter", () => ((TextBlock)w.FindName("Conv")!).Text == $"conv-{p}:abc" ? true : throw new Exception("text=[" + ((TextBlock)w.FindName("Conv")!).Text + "]")),
                    ("Thickness", () => ((Border)w.FindName("Pad")!).Padding == new Thickness(1, 2, 3, 4)),
                    ("x:Int32", () => (int)((Border)w.FindName("Pad")!).Tag == 7),
                    ("ComponentResourceKey", () => C(((Border)w.FindName("Rck")!).Background) == Rgb(0x0F, 0x0E, 0x0D)),
                    ("relative Sub/ merge", () => C(((Border)w.FindName("Sub")!).Background) == Rgb(0xA1, 0xB2, 0xC3)),
                    ("x:Shared=False", () => !ReferenceEquals(((Border)w.FindName("Sh1")!).Background, ((Border)w.FindName("Sh2")!).Background)) };
                var bad = new List<string>();
                foreach (var (n, f) in parts) { try { if (!f()) bad.Add(n); } catch (Exception e) { bad.Add(n + "(" + e.GetType().Name + ": " + e.Message.Split('\n')[0] + ")"); } }
                var ok = bad.Count == 0; if (!ok) Console.WriteLine("     failing parts: " + string.Join("; ", bad));
                w.Close(); return ok;
            });
            Check($"[{lib}] shown window: implicit style + Generic.xaml template of the custom control, implicit DataTemplate", () =>
            {
                Window w = p == "X" ? new WinRichX() : new WinRichB(); Pump(w);
                var c = (Control)w.FindName("Custom")!; c.ApplyTemplate();
                var cc = (ContentControl)w.FindName("Item")!; var cp = (ContentPresenter)VisualTreeHelper.GetChild(cc, 0);
                var ok = (string)c.Tag == "implicit-" + p && c.Template?.FindName("PART_Text", c) is TextBlock
                    && VisualTreeHelper.GetChildrenCount(cp) > 0 && VisualTreeHelper.GetChild(cp, 0) is TextBlock t && (string)t.Tag == "template-" + p;
                w.Close(); return ok;
            });
            Check($"[{lib}] DynamicResource resolved later when a {p}Late dictionary is merged at run time", () =>
            {
                Window w = p == "X" ? new WinRichX() : new WinRichB(); Pump(w);
                var late = (TextBlock)w.FindName("Late")!; var before = C(late.Foreground);
                w.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri($"/Lib{p};component/{p}Late.xaml", UriKind.Relative) });
                w.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
                var ok = before != Rgb(0xC0, 0xFF, 0xEE) && C(late.Foreground) == Rgb(0xC0, 0xFF, 0xEE); w.Close(); return ok;
            });
            Check($"[{lib}] UserControl whose own Resources merge the OTHER mode's dictionary (StaticResource into it)", () =>
            {
                Window w = p == "X" ? new WinRichX() : new WinRichB(); var m = (FrameworkElement)w.FindName("Merger")!;
                var other = p == "X" ? "B" : "X"; var t = (TextBlock)m.FindName("T")!;
                return t.Text == "hello-" + other && C(t.Foreground) == Rgb(0x11, 0x22, 0x33);
            });
            foreach (var uri in new[] { $"/Lib{p};v1.0.0.0;component/{p}Dict.xaml", $"pack://application:,,,/Lib{p};v1.0.0.0;component/{p}Dict.xaml", $"/lib{p.ToLowerInvariant()};component/{p.ToLowerInvariant()}dict.xaml" })
                Check($"[{lib}] pack URI form {uri}", () => new ResourceDictionary { Source = new Uri(uri, uri.StartsWith("pack") ? UriKind.Absolute : UriKind.Relative) }.Contains(p + "Brush"));
            Check($"[{lib}] Source getter, independent instances, repeated lookups give the same cached instance", () =>
            {
                var u = new Uri($"/Lib{p};component/{p}Dict.xaml", UriKind.Relative);
                var a = new ResourceDictionary { Source = u }; var b2 = new ResourceDictionary { Source = u };
                return a.Source == u && !ReferenceEquals(a, b2) && ReferenceEquals(a[p + "ButtonStyle"], a[p + "ButtonStyle"]) && ReferenceEquals(a[p + "Brush"], a[p + "Brush"]);
            });
            Check($"[{lib}] entries stay lazy through Source: loading creates nothing, the first lookup creates one, later lookups the same one", () =>
            {
                ref int count = ref (p == "X" ? ref XCounted.Count : ref BCounted.Count);
                var before = count;
                var d = new ResourceDictionary { Source = new Uri($"/Lib{p};component/{p}Dict.xaml", UriKind.Relative) };
                if (count != before) throw new Exception($"loading created {count - before} entries");
                var first = d[p + "Counted"]; var second = d[p + "Counted"];
                if (count != before + 1) throw new Exception($"first lookups created {count - before} instances");
                return ReferenceEquals(first, second);
            });
            Check($"[{lib}] Source = /{p}ClassDict.xaml (a dictionary with x:Class) from code and XAML-free lookup", () =>
            {
                var d = new ResourceDictionary { Source = new Uri($"/Lib{p};component/{p}ClassDict.xaml", UriKind.Relative) };
                return C(d[p + "ClassBrush"]) == Rgb(0x77, 0x88, 0x99) && d[p + "ClassStyle"] is Style && !ReferenceEquals(d[p + "ClassShared"], d[p + "ClassShared"]);
            });
            Check($"[{lib}] Frame navigation to /Lib{p};component/{p}Page.xaml", () =>
            {
                var f = new Frame(); var w = new Window { Content = f }; Pump(w);
                f.Source = new Uri($"/Lib{p};component/{p}Page.xaml", UriKind.Relative);
                for (int i = 0; i < 100 && f.Content == null; i++) { w.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle); System.Threading.Thread.Sleep(20); }
                var ok = f.Content is Page; w.Close(); return ok;
            });
        }
        Check("equivalence: XDict (XSG) and BDict (BAML) loaded through Source have the same keys, value types and style setters", () =>
        {
            var x = new ResourceDictionary { Source = new Uri("/LibX;component/XDict.xaml", UriKind.Relative) };
            var b = new ResourceDictionary { Source = new Uri("/LibB;component/BDict.xaml", UriKind.Relative) };
            string K(object k) => k is string s ? s.Substring(1) : k is Type t ? t.Name.Substring(1) : k is DataTemplateKey d ? "DT:" + ((Type)d.DataType!).Name.Substring(1) : k is ComponentResourceKey c ? "RCK:" + c.ResourceId : k.GetType().Name;
            var kx = x.Keys.Cast<object>().Select(K).OrderBy(v => v).ToList(); var kb = b.Keys.Cast<object>().Select(K).OrderBy(v => v).ToList();
            // An x:Shared=False entry is not copied (every lookup must create it): it is found through the generated dictionary kept as a merged dictionary.
            foreach (var missing in kb.Except(kx)) if (x["X" + missing] == null) throw new Exception("key missing in XSG dictionary: " + missing);
            if (kx.Except(kb).Any()) throw new Exception("keys only in XSG dictionary: " + string.Join(",", kx.Except(kb)));
            foreach (var key in x.Keys.Cast<object>().Where(k => kb.Contains(K(k))))
            {
                var other = b.Keys.Cast<object>().First(o => K(o) == K(key)); var vx = x[key]; var vb = b[other];
                if (vx.GetType().Name.Substring(1) != vb.GetType().Name.Substring(1) && vx.GetType() != vb.GetType()) throw new Exception($"{K(key)}: {vx.GetType().Name} vs {vb.GetType().Name}");
                if (vx is Style sx && vb is Style sb && (sx.Setters.Count != sb.Setters.Count || sx.TargetType.Name.Substring(1) != sb.TargetType.Name.Substring(1) && sx.TargetType != sb.TargetType)) throw new Exception($"{K(key)}: style differs");
            }
            return true;
        });
        Check("[app] own Page via Application.LoadComponent(/PageA.xaml)", () => ((TextBlock)((Page)Application.LoadComponent(new Uri("/PageA.xaml", UriKind.Relative))).Content).Text == "page-app");
        return 0;
    }
}

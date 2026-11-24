using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace XsgAot;

/// <summary>What the prototype proves, printed as name=value lines and a final PASS/FAIL.</summary>
internal static class SelfCheck
{
    /// <summary>The visual tree as lines of "depth type width x height": the same window in the JIT build (BAML Aero2) and in the
    /// NativeAOT build (Aero2 compiled by XSG) must print the same tree.</summary>
    public static void Dump(DependencyObject root, int depth = 0)
    {
        var size = root is FrameworkElement fe ? $"{fe.ActualWidth:0.#}x{fe.ActualHeight:0.#}" : "-";
        Console.WriteLine($"{new string(' ', depth * 2)}{root.GetType().Name} {size}");
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            Dump(VisualTreeHelper.GetChild(root, i), depth + 1);
        }
    }

    public static void Run(MainWindow window)
    {
        if (Environment.GetEnvironmentVariable("XSGAOT_CONVERTERS") == "1")
        {
            Console.WriteLine($"IsDynamicCodeSupported={System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported}");
            foreach (var t in new[] { typeof(bool), typeof(int), typeof(double), typeof(string), typeof(Visibility), typeof(Thickness) })
            {
                Console.WriteLine($"TypeDescriptor.GetConverter({t.Name}) = {System.ComponentModel.TypeDescriptor.GetConverter(t).GetType().FullName}");
            }
        }

        if (Environment.GetEnvironmentVariable("XSGAOT_DUMP") == "1")
        {
            Dump(window);
            return;
        }

        var ok = true;
        void Check(string name, bool condition, string detail)
        {
            ok &= condition;
            Console.WriteLine($"{(condition ? "ok  " : "FAIL")} {name}: {detail}");
        }

        Console.WriteLine($"nativeaot={!System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported}");

        // 1. The Window template came from the XSG theme (no BAML): Window > Border > AdornerDecorator > ContentPresenter.
        var chrome = VisualTreeHelper.GetChildrenCount(window) > 0 ? VisualTreeHelper.GetChild(window, 0) : null;
        var decorator = chrome is not null && VisualTreeHelper.GetChildrenCount(chrome) > 0 ? VisualTreeHelper.GetChild(chrome, 0) : null;
        Check("window template", chrome is Border && decorator is System.Windows.Documents.AdornerDecorator,
            $"{chrome?.GetType().Name} > {decorator?.GetType().Name}");

        var root = (FrameworkElement)window.Content;
        Check("layout", root.ActualWidth > 0 && root.ActualHeight > 0, $"{root.ActualWidth}x{root.ActualHeight}");

        // 2. The Button template too, with its named part and content.
        var button = (Button)window.FindName("Action")!;
        var border = button.Template?.FindName("border", button) as Border;
        Check("button template", border is not null && border.ActualWidth > 0, $"border={border?.ActualWidth}x{border?.ActualHeight} background={border?.Background}");

        // 3. Compiled bindings: source -> target, then TwoWay target -> source, no reflection over the view model.
        var greeting = (TextBlock)window.FindName("Greeting")!;
        var nameBox = (TextBox)window.FindName("NameBox")!;
        Check("binding source->target", greeting.Text == "Hello, Ada" && nameBox.Text == "Ada", $"greeting='{greeting.Text}' name='{nameBox.Text}'");

        window.ViewModel.Person.Name = "Grace";
        Check("binding INPC update", greeting.Text == "Hello, Grace" && nameBox.Text == "Grace", $"greeting='{greeting.Text}' name='{nameBox.Text}'");

        nameBox.Text = "Linus";
        Check("binding TwoWay target->source", window.ViewModel.Person.Name == "Linus" && greeting.Text == "Hello, Linus",
            $"vm.Name='{window.ViewModel.Person.Name}' greeting='{greeting.Text}'");

        var path = System.Windows.Data.BindingOperations.GetBinding(nameBox, TextBox.TextProperty)?.Path;
        Check("binding is compiled", path?.PathParameters.Count == 2 && path.PathParameters[0] is System.ComponentModel.PropertyDescriptor,
            $"path='{path?.Path}' parameters={path?.PathParameters.Count}");

        // 4. A template node that needs code the factory cannot express (Grid.RowDefinitions): filled by the factory's initializer.
        var gridButton = (Button)window.FindName("Grid")!;
        var layout = gridButton.Template?.FindName("layout", gridButton) as Grid;
        Check("template initializer", layout is { RowDefinitions.Count: 2 }, $"rows={layout?.RowDefinitions.Count} height0={layout?.RowDefinitions[0].Height}");

        // 5. What a real application has: App.xaml with a StartupUri (no BAML to load the window from), a merged dictionary by Source, and
        //    a UserControl with its own XAML that uses App.xaml's resources.
        Check("startup uri", ReferenceEquals(Application.Current.MainWindow, window), $"MainWindow is {Application.Current.MainWindow?.GetType().Name}");
        var accent = Application.Current.Resources["AccentBrush"] as System.Windows.Media.SolidColorBrush;
        Check("merged dictionary", accent?.Color == System.Windows.Media.Color.FromRgb(0x33, 0x66, 0xCC)
            && Application.Current.Resources["CardPadding"] is Thickness { Left: 8, Top: 4 }, $"AccentBrush={accent?.Color} CardPadding={Application.Current.Resources["CardPadding"]}");
        var card = (Card)window.FindName("TheCard")!;
        var cardBorder = card.Content as Border;
        Check("user control", card.Title.StartsWith("a user control") && cardBorder?.Background is System.Windows.Media.SolidColorBrush { Color: { R: 0xEE, G: 0xF3, B: 0xFB } },
            $"title='{card.Title}' background={cardBorder?.Background}");

        // 6. A pack resource: <Image Source="Assets/logo.png"/> reads the image from the assembly's .g.resources, written by the XSG resource target.
        var logo = (Image)window.FindName("Logo")!;
        var bitmap = logo.Source as System.Windows.Media.Imaging.BitmapSource;
        Check("image resource", bitmap is { PixelWidth: 48, PixelHeight: 48 } && logo.ActualWidth == 48, $"source={bitmap?.GetType().Name} {bitmap?.PixelWidth}x{bitmap?.PixelHeight} element={logo.ActualWidth}x{logo.ActualHeight}");

        // 7. A gallery of the rest of the controls an application uses (Menu, ToolBar, TabControl, TreeView, ListView, DataGrid, Calendar,
        //    PasswordBox, Expander, ...), applied and laid out, with data templates over an ObservableCollection.
        try
        {
            var gallery = new Gallery();
            var host = new Window { Content = gallery, Width = 700, Height = 500 };
            host.Show();
            host.UpdateLayout();
            int count = 0, missingTemplate = 0, columnHeaders = 0;
            var dumpPath = Environment.GetEnvironmentVariable("XSGAOT_GALLERY");
            var dump = dumpPath is null ? null : new System.Text.StringBuilder();
            var depth = 0;
            void Walk(DependencyObject node)
            {
                count++;
                dump?.AppendLine(new string(' ', depth * 2) + node.GetType().Name + (node is FrameworkElement fe ? $" {fe.ActualWidth:0.#}x{fe.ActualHeight:0.#}" : ""));
                depth++;
                try { WalkChildren(node); } finally { depth--; }
            }
            void WalkChildren(DependencyObject node)
            {
                if (node is Control c && c.Template is null) missingTemplate++;
                if (node is System.Windows.Controls.GridViewColumnHeader { Content: not null }) columnHeaders++;
                for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(node); i++) Walk(System.Windows.Media.VisualTreeHelper.GetChild(node, i));
            }
            Walk(host);
            if (dumpPath is not null) System.IO.File.WriteAllText(dumpPath, dump!.ToString());
            var items = (ListBox)gallery.FindName("Items")!;
            var tree = (TreeView)gallery.FindName("Tree")!;
            var table = (ListView)gallery.FindName("Table")!;
            var grid = (DataGrid)gallery.FindName("Grid")!;
            Check("gallery", count > 200 && missingTemplate == 0 && columnHeaders == 2 && items.Items.Count == 3 && table.Items.Count == 3 && grid.Items.Count == 3 && tree.Items.Count == 1,
                $"visuals={count} controlsWithoutTemplate={missingTemplate} columnHeaders={columnHeaders} listItems={items.Items.Count}[{string.Join(",", items.Items.Cast<object>().Select(o => (o as Row)?.Label ?? o?.GetType().Name))}] tableRows={table.Items.Count} gridRows={grid.Items.Count} treeRoots={tree.Items.Count}");
            host.Close();
        }
        catch (Exception e)
        {
            Check("gallery", false, e.GetType().Name + ": " + e.Message);
        }

        // 8. Styles with triggers, converters and a MultiBinding, a command, a state-managed template, a ToolTip, an ItemsControl with its own panel.
        try
        {
            var dynamics = new Dynamics();
            var host = new Window { Content = dynamics, Width = 400, Height = 400 };
            host.Show();
            host.UpdateLayout();
            var model = (DynamicsModel)dynamics.DataContext;
            var upper = (TextBlock)dynamics.FindName("Upper")!;
            var joined = (TextBlock)dynamics.FindName("Joined")!;
            var pulse = (Border)dynamics.FindName("PulseBorder")!;
            var before = (pulse.Background as System.Windows.Media.SolidColorBrush)?.Color;
            var stateButton = (Button)dynamics.FindName("StateBtn")!;
            var edit = (TextBox)dynamics.FindName("Edit")!;
            var repeater = (ItemsControl)dynamics.FindName("Repeater")!;
            var firstState = joined.Text;
            var firstUpper = upper.Text;
            stateButton.Command.Execute(null);                                   // Count 0 -> 1, On = true
            host.UpdateLayout();
            var after = (pulse.Background as System.Windows.Media.SolidColorBrush)?.Color;
            var afterBump = joined.Text;
            var stateRoot = (Border)stateButton.Template.FindName("Root", stateButton);
            var stateWorked = VisualStateManager.GoToState(stateButton, "MouseOver", false);
            edit.Text = "grace";
            var tip = ((TextBlock)dynamics.FindName("ToolTipHost")!).ToolTip;
            Check("dynamics", firstUpper == "ADA" && firstState == "ada/0" && afterBump == "ada/1"
                    && before == System.Windows.Media.Colors.LightGray && after == System.Windows.Media.Colors.Gold
                    && model.Name == "grace" && tip is "grace" && stateWorked && repeater.Items.Count == 3 && stateRoot is not null,
                $"upper='{firstUpper}' joined='{firstState}'->'{afterBump}' background={before}->{after} name='{model.Name}' tip='{tip}' items={repeater.Items.Count} stateManager={stateWorked}");
            host.Close();
        }
        catch (Exception e)
        {
            Check("dynamics", false, e.GetType().Name + ": " + e.Message);
        }

        Console.WriteLine(ok ? "PASS" : "FAIL");
        Environment.ExitCode = ok ? 0 : 1;
    }
}

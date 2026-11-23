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

        Console.WriteLine(ok ? "PASS" : "FAIL");
        Environment.ExitCode = ok ? 0 : 1;
    }
}

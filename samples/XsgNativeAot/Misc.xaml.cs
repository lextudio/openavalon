using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace XsgAot;

public partial class Misc : UserControl
{
    public int Clicks;
    public Misc() { InitializeComponent(); DataContext = new MiscModel(); }
    private void OnClick(object sender, RoutedEventArgs e) => Clicks++;
    public void Click() => Clicker.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
}

public abstract class Animal { public string Name { get; set; } = ""; }
public sealed class Cat : Animal { }
public sealed class Dog : Animal { }
public sealed class Number { public int Value { get; set; } }

public sealed class MiscModel
{
    public const string Caption = "click me";
    public Animal Pet { get; } = new Cat { Name = "tom" };
    public Animal Dog { get; } = new Dog { Name = "rex" };
    public ObservableCollection<Animal> Pets { get; } = new() { new Cat { Name = "a" }, new Dog { Name = "b" } };
    public ObservableCollection<Number> Numbers { get; } = new() { new Number { Value = 2 }, new Number { Value = 9 }, new Number { Value = 5 } };
    public int Age { get; set; } = 3;
}

public sealed class KindSelector : DataTemplateSelector
{
    public override DataTemplate SelectTemplate(object item, DependencyObject container) =>
        (DataTemplate)((FrameworkElement)container).FindResource(item is Cat ? new DataTemplateKey(typeof(Cat)) : "Dog");
}

public sealed class PositiveRule : System.Windows.Controls.ValidationRule
{
    public override ValidationResult Validate(object value, CultureInfo cultureInfo) =>
        int.TryParse(value as string, out var n) && n > 0 ? ValidationResult.ValidResult : new ValidationResult(false, "must be positive");
}

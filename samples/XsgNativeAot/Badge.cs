using System.Windows;
using System.Windows.Controls;

[assembly: ThemeInfo(ResourceDictionaryLocation.None, ResourceDictionaryLocation.SourceAssembly)]

namespace XsgAot;

/// <summary>A custom control whose default style comes from Themes/Generic.xaml of this assembly.</summary>
public class Badge : Control
{
    static Badge() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Badge), new FrameworkPropertyMetadata(typeof(Badge)));

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(Badge), new PropertyMetadata(""));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }
}

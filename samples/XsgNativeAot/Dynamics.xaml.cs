using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Input;

namespace XsgAot;

public partial class Dynamics : System.Windows.Controls.UserControl
{
    public Dynamics()
    {
        InitializeComponent();
        DataContext = new DynamicsModel();
    }
}

public sealed class DynamicsModel : INotifyPropertyChanged
{
    private string _name = "ada";
    private int _count;
    public string Name { get => _name; set { _name = value; Raise(nameof(Name)); } }
    public int Count { get => _count; set { _count = value; Raise(nameof(Count)); } }
    public bool On => _count > 0;
    public System.Collections.Generic.List<string> Names { get; } = new() { "x", "y", "z" };
    public ICommand Bump { get; }
    public DynamicsModel() => Bump = new Relay(() => { Count++; Raise(nameof(On)); });
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class Relay(Action run) : ICommand
{
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => run();
    public event EventHandler? CanExecuteChanged { add { } remove { } }
}

public sealed class UpperConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => ((string)value).ToUpperInvariant();
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => value;
}

public sealed class JoinConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture) => string.Join("/", values);
    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

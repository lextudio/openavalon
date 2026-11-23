using System.ComponentModel;

namespace XsgAot;

public sealed class MainViewModel
{
    public Person Person { get; } = new();
}

public sealed class Person : INotifyPropertyChanged
{
    private string _name = "Ada";

    public string Name
    {
        get => _name;
        set
        {
            _name = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Name)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Greeting)));
        }
    }

    public string Greeting => "Hello, " + _name;

    public event PropertyChangedEventHandler? PropertyChanged;
}

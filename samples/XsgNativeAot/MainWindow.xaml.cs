namespace XsgAot;

public partial class MainWindow : System.Windows.Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContext = ViewModel;
    }

    public MainViewModel ViewModel { get; } = new();

    public string StatusText => Status?.Text ?? "<null>";
}

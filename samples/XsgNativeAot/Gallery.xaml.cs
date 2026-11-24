using System.Collections.ObjectModel;

namespace XsgAot;

public sealed class Row
{
    public string Label { get; set; } = "";
    public bool Done { get; set; }
}

public partial class Gallery : System.Windows.Controls.UserControl
{
    public Gallery()
    {
        InitializeComponent();
        DataContext = new GalleryModel();
    }
}

public sealed class GalleryModel
{
    public ObservableCollection<Row> Rows { get; } = new() { new Row { Label = "alpha", Done = true }, new Row { Label = "beta" }, new Row { Label = "gamma" } };
}

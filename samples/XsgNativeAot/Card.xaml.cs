namespace XsgAot;

public partial class Card : System.Windows.Controls.UserControl
{
    public Card() => InitializeComponent();

    public string Title
    {
        get => Caption?.Text ?? "";
        set { if (Caption is not null) Caption.Text = value; }
    }
}

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace XsgAot;

/// <summary>A FrameworkElement that draws with a DrawingContext: text (also with an unknown font family), dashed pens, an image brush and a geometry. Each step records whether it threw.</summary>
public sealed class DrawingVisualHost : FrameworkElement
{
    public bool Drawn;
    public int Failures;
    public string Detail = "";

    protected override void OnRender(DrawingContext dc)
    {
        var steps = new List<string>();
        void Step(string name, Action action)
        {
            try { action(); steps.Add(name + ":ok"); }
            catch (Exception e) { Failures++; steps.Add(name + ":" + e.GetType().Name); }
        }

        Step("text", () =>
        {
            var text = new FormattedText("Hello", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Arial"), 14, Brushes.Black, 1.0);
            dc.DrawText(text, new Point(5, 5));
        });
        Step("fallback", () => dc.DrawText(new FormattedText("Fallback", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("No Such Font Family"), 14, Brushes.Black, 1.0), new Point(60, 5)));
        Step("dash", () => dc.DrawLine(new Pen(Brushes.Black, 1) { DashStyle = new DashStyle(new double[] { 2, 2 }, 0) }, new Point(0, 40), new Point(100, 40)));
        Step("dashes", () => dc.DrawRectangle(null, new Pen(Brushes.Gray, 1) { DashStyle = DashStyles.Dot }, new Rect(5, 50, 50, 20)));
        Step("image", () => dc.DrawRectangle(new ImageBrush(new System.Windows.Media.Imaging.BitmapImage(new Uri("Assets/logo.png", UriKind.Relative))), null, new Rect(120, 5, 40, 40)));
        Step("geometry", () => dc.DrawGeometry(Brushes.Red, new Pen(Brushes.Black, 1), Geometry.Parse("M 0,0 L 20,0 20,20 Z")));
        Drawn = true;
        Detail = string.Join(" ", steps);
    }
}

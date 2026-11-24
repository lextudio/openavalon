using System.Globalization;
using System.Windows.Data;
namespace @NS@;
public class @P@Conv : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => "conv-@P@:" + value;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

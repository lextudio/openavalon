<Window x:Class="App@MODE@.Win@KIND@@P@"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:l="clr-namespace:@LIB@;assembly=@LIB@" Title="w" Width="300" Height="200">
  <StackPanel>
    <l:@P@Control x:Name="Ctl" />
    <l:@P@Custom x:Name="Custom" />
    <ContentControl x:Name="Item"><l:@P@Item /></ContentControl>
  </StackPanel>
</Window>

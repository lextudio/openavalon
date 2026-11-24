<Window x:Class="App@MODE@.Win@KIND@@P@"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:l="clr-namespace:@LIB@;assembly=@LIB@" Title="w" Width="300" Height="200">
  <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries>
    <l:@P@ClassDict />
  </ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
  <StackPanel>
    <TextBlock x:Name="ClassBrush" Foreground="{StaticResource @P@ClassBrush}" />
    <Border x:Name="Styled" Style="{StaticResource @P@ClassStyle}" />
    <Border x:Name="Sh1" Background="{StaticResource @P@ClassShared}" />
    <Border x:Name="Sh2" Background="{StaticResource @P@ClassShared}" />
  </StackPanel>
</Window>

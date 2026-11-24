<Window x:Class="App@MODE@.Win@KIND@@P@"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:l="clr-namespace:@LIB@;assembly=@LIB@" Title="w" Width="300" Height="200">
  <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries>
    <ResourceDictionary Source="/@LIB@;component/@P@Dict.xaml" />
  </ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
  <StackPanel>
    <Button x:Name="Styled" Style="{StaticResource @P@ButtonStyle}" />
    <TextBlock x:Name="Dyn" Foreground="{DynamicResource @P@Brush}" Text="{StaticResource @P@Text}" />
  </StackPanel>
</Window>

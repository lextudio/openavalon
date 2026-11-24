<Window x:Class="App@MODE@.Win@KIND@@P@"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:l="clr-namespace:@LIB@;assembly=@LIB@" Title="w" Width="300" Height="300">
  <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries>
    <ResourceDictionary Source="/@LIB@;component/@P@Dict.xaml" />
    <ResourceDictionary Source="/@LIB@;component/@P@Cross.xaml" />
  </ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
  <StackPanel>
    <Button x:Name="Templated" Style="{StaticResource @P@TemplatedStyle}" Content="t" />
    <Button x:Name="Disabled" Style="{StaticResource @P@TemplatedStyle}" IsEnabled="False" Content="d" />
    <TextBlock x:Name="Conv" Text="{Binding Source=abc, Converter={StaticResource @P@Conv}}" />
    <Border x:Name="Pad" Padding="{StaticResource @P@Pad}" Tag="{StaticResource @P@Int}" />
    <Border x:Name="Rck" Background="{DynamicResource {ComponentResourceKey TypeInTargetAssembly={x:Type l:@P@Custom}, ResourceId=Rck}}" />
    <Border x:Name="Sub" Background="{StaticResource @P@SubBrush}" />
    <Border x:Name="Sh1" Background="{StaticResource @P@Shared}" />
    <Border x:Name="Sh2" Background="{StaticResource @P@Shared}" />
    <l:@P@Custom x:Name="Custom" />
    <ContentControl x:Name="Item"><l:@P@Item /></ContentControl>
    <TextBlock x:Name="Late" Foreground="{DynamicResource @P@LateBrush}" />
    <l:@P@Merger x:Name="Merger" />
  </StackPanel>
</Window>

#requires -Version 5.1
<#
.SYNOPSIS
    Standalone WPF control panel for the existing zapret installation.
.DESCRIPTION
    Keeps zapret.bat and the classic console menu intact. This separate GUI
    provides service status/start/stop, the guided Auto-Setup console, site
    recommendations, diagnostics, and links to the existing advanced menu.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:AppRoot = $PSScriptRoot
$script:ModulePath = Join-Path $script:AppRoot 'src\Zapret.psm1'
$script:CliPath = Join-Path $script:AppRoot 'zapret.ps1'
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$script:ActivityEntries = New-Object 'System.Collections.Generic.List[string]'

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml
} catch {
    Write-Error ("This control panel requires Windows PowerShell 5.1 with WPF: {0}" -f $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $script:ModulePath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:CliPath -PathType Leaf)) {
    [void][System.Windows.MessageBox]::Show('Не найдены src\Zapret.psm1 или zapret.ps1. Распакуйте приложение рядом с файлами проекта.', 'OpenZapret', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

# Service controls need administrator rights. Elevate only this separate GUI;
# the original zapret.bat launcher is not changed.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $elevatedArgs = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath $script:PowerShellExe -ArgumentList $elevatedArgs -Verb RunAs -WindowStyle Hidden | Out-Null
        exit 0
    }
} catch {
    [void][System.Windows.MessageBox]::Show(("Не удалось запросить права администратора: {0}" -f $_.Exception.Message), 'OpenZapret', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

try {
    Import-Module -Name $script:ModulePath -Force -ErrorAction Stop
} catch {
    [void][System.Windows.MessageBox]::Show(("Не удалось загрузить модуль zapret: {0}" -f $_.Exception.Message), 'OpenZapret', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenZapret" Height="780" Width="1180" MinHeight="680" MinWidth="980"
        WindowStartupLocation="CenterScreen" Background="#0F141E" Foreground="#E8EEF8"
        FontFamily="Segoe UI Variable, Segoe UI" ResizeMode="CanResize" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="PanelBrush" Color="#1C2335" />
    <SolidColorBrush x:Key="PanelAltBrush" Color="#161E2F" />
    <SolidColorBrush x:Key="LineBrush" Color="#2C374E" />
    <SolidColorBrush x:Key="MutedBrush" Color="#8E9AB5" />
    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Foreground" Value="#D6E1F5" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="Padding" Value="14,10" />
      <Setter Property="Margin" Value="6,2,6,2" />
      <Setter Property="FontSize" Value="13.5" />
      <Setter Property="FontWeight" Value="Normal" />
      <Setter Property="HorizontalContentAlignment" Value="Left" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="navBorder" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}" BorderThickness="0">
              <ContentPresenter VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="navBorder" Property="Background" Value="#242E42" /></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="navBorder" Property="Background" Value="#2E3A52" /></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4" /></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="White" />
      <Setter Property="Background" Value="#4F7DF3" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="Padding" Value="16,9" />
      <Setter Property="Margin" Value="0,0,8,0" />
      <Setter Property="FontSize" Value="13.5" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="buttonBorder" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="buttonBorder" Property="Background" Value="#5B85F5" /></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="buttonBorder" Property="Background" Value="#3D6BE0" /></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4" /></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Foreground" Value="#DCE6F5" />
      <Setter Property="Background" Value="#202D44" />
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Foreground" Value="#FFE5E8" />
      <Setter Property="Background" Value="#3A2636" />
      <Setter Property="Margin" Value="0,0,10,0" />
    </Style>
    <Style x:Key="CardBorder" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource PanelBrush}" />
      <Setter Property="BorderBrush" Value="#232D42" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="CornerRadius" Value="12" />
      <Setter Property="Padding" Value="18" />
      <Setter Property="Margin" Value="0,0,0,16" />
    </Style>
    <Style x:Key="SmallLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
      <Setter Property="FontSize" Value="11" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Margin" Value="0,0,0,8" />
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#0D1627" />
      <Setter Property="Foreground" Value="#E8EEF8" />
      <Setter Property="BorderBrush" Value="#2A3953" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="MaxDropDownHeight" Value="320" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="toggleButton"
                            Focusable="False"
                            ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            Foreground="{TemplateBinding Foreground}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="chromeBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="1"
                            CornerRadius="9">
                      <ContentPresenter />
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="chromeBorder" Property="Background" Value="#16223A" />
                      </Trigger>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="chromeBorder" Property="Background" Value="#1A2941" />
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="30" />
                  </Grid.ColumnDefinitions>
                  <ContentPresenter Grid.Column="0"
                                    Margin="{TemplateBinding Padding}"
                                    VerticalAlignment="Center"
                                    HorizontalAlignment="Left"
                                    Content="{TemplateBinding SelectionBoxItem}"
                                    ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                    ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" />
                  <Path Grid.Column="1"
                        HorizontalAlignment="Center"
                        VerticalAlignment="Center"
                        Data="M 0 0 L 4 4 L 8 0 Z"
                        Fill="{TemplateBinding Foreground}" />
                </Grid>
              </ToggleButton>
              <Popup x:Name="PART_Popup"
                     Placement="Bottom"
                     AllowsTransparency="True"
                     PopupAnimation="Slide"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border x:Name="dropDownBorder"
                        Background="#10192B"
                        BorderBrush="#2A3953"
                        BorderThickness="1"
                        CornerRadius="10"
                        MinWidth="{TemplateBinding ActualWidth}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer SnapsToDevicePixels="True"
                                HorizontalScrollBarVisibility="Disabled"
                                VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter />
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="Foreground" Value="#E8EEF8" />
      <Setter Property="Padding" Value="11,8" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="itemBorder"
                    Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}"
                    CornerRadius="7"
                    Margin="4,2">
              <ContentPresenter />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="itemBorder" Property="Background" Value="#1A2941" />
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="itemBorder" Property="Background" Value="#1A2941" />
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="itemBorder" Property="Background" Value="#243958" />
                <Setter Property="Foreground" Value="#FFFFFF" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230" />
      <ColumnDefinition Width="*" />
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#0F1728" BorderBrush="#202B40" BorderThickness="0,0,1,0">
      <Grid Margin="21,24,21,20">
        <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="42" Height="42" CornerRadius="13" Background="#4F7DF3" VerticalAlignment="Center">
              <TextBlock Text="Z" FontSize="24" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="White" />
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="ZAPRET" FontSize="16" FontWeight="Bold" Foreground="#F3F6FC" />
              <TextBlock Text="CONTROL CENTER" FontSize="9" FontWeight="SemiBold" Foreground="#8493AB" />
            </StackPanel>
          </StackPanel>
          <Border Height="1" Background="#202B40" Margin="0,24,0,20" />
        </StackPanel>
        <StackPanel Grid.Row="1">
          <TextBlock Text="РАБОЧЕЕ ПРОСТРАНСТВО" Style="{StaticResource SmallLabel}" Margin="12,0,0,9" />
          <Button x:Name="navHome" Style="{StaticResource NavButton}" Content="   Обзор" Background="#1A2941" />
          <Button x:Name="navStrategies" Style="{StaticResource NavButton}" Content="   Стратегии" />
          <Button x:Name="navNetwork" Style="{StaticResource NavButton}" Content="   Сеть и DNS" />
          <Button x:Name="navSites" Style="{StaticResource NavButton}" Content="   Мои сайты" />
          <Button x:Name="navMore" Style="{StaticResource NavButton}" Content="   Дополнительно" />
        </StackPanel>
        <StackPanel Grid.Row="2">
          <Border Height="1" Background="#202B40" Margin="0,0,0,16" />
          <TextBlock x:Name="txtVersion" Text="OpenZapret" Foreground="#AAB6C9" FontSize="11" />
          <TextBlock Text="Старый zapret.bat остаётся без изменений." TextWrapping="Wrap" Foreground="#65738B" FontSize="10" Margin="0,5,0,0" />
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Column="1" Margin="30,23,30,18">
      <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock x:Name="txtPageTitle" Text="Управление zapret" FontSize="26" FontWeight="SemiBold" Foreground="#F4F7FC" />
          <TextBlock x:Name="txtPageSubtitle" Text="Быстрые действия и понятный статус — без консольного меню." Foreground="#91A0B8" FontSize="13" Margin="0,5,0,0" />
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="btnBackToWizard" Content="↩ Вернуться к действию" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" Padding="15,10" Visibility="Collapsed" />
          <Button x:Name="btnRefresh" Content="Обновить статус" Style="{StaticResource SecondaryButton}" Margin="0" Padding="15,10" />
          <Button x:Name="btnHelp" Content="Инструкция" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" Padding="15,10" />
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="0,22,0,14">
        <Grid x:Name="pageHome" Visibility="Visible">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <UniformGrid Columns="3" Margin="0,0,0,4">
                <Border Style="{StaticResource CardBorder}">
                  <StackPanel>
                    <TextBlock Text="СОСТОЯНИЕ СЛУЖБЫ" Style="{StaticResource SmallLabel}" />
                    <TextBlock x:Name="txtServiceState" Text="Проверка…" FontSize="21" FontWeight="SemiBold" Foreground="#EAF0FA" />
                    <TextBlock x:Name="txtServiceDetail" Text="" Foreground="#91A0B8" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap" />
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBorder}">
                  <StackPanel>
                    <TextBlock Text="ТЕКУЩИЙ ПРОФИЛЬ" Style="{StaticResource SmallLabel}" />
                    <TextBlock x:Name="txtStrategy" Text="—" FontSize="16" FontWeight="SemiBold" Foreground="#EAF0FA" TextWrapping="Wrap" />
                    <TextBlock Text="Профиль, сохранённый в службе" Foreground="#91A0B8" FontSize="11" Margin="0,6,0,0" />
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="IP-ФИЛЬТР" Style="{StaticResource SmallLabel}" />
                    <TextBlock x:Name="txtIpState" Text="—" FontSize="18" FontWeight="SemiBold" Foreground="#EAF0FA" />
                    <TextBlock Text="Состояние списка IP" Foreground="#91A0B8" FontSize="11" Margin="0,6,0,0" />
                  </StackPanel>
                </Border>
              </UniformGrid>

              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,14">
                <StackPanel>
                  <TextBlock Text="Быстрое управление" FontSize="18" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Запускайте уже установленную службу, временно останавливайте её или откройте мастер подбора." Foreground="#91A0B8" FontSize="12" Margin="0,6,0,18" TextWrapping="Wrap" />
                  <WrapPanel>
                    <Button x:Name="btnStartService" Content="Запустить службу" Style="{StaticResource PrimaryButton}" IsEnabled="False" />
                    <Button x:Name="btnStopService" Content="Остановить" Style="{StaticResource DangerButton}" IsEnabled="False" />
                    <Button x:Name="btnAutoSetup" Content="Автонастройка" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnSpeedTest" Content="Тест скорости" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock Text="Автонастройка проверяет варианты отдельно; установка и системные изменения требуют подтверждения в мастере." Foreground="#75849C" FontSize="11" Margin="0,14,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>

              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,14">
                <StackPanel>
                  <TextBlock Text="Автозащита" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtWatchdogState" Text="Фоновая проверка обхода выключена." Foreground="#91A0B8" FontSize="12" Margin="0,6,0,12" TextWrapping="Wrap" />
                  <WrapPanel>
                    <Button x:Name="btnWatchdogToggle" Content="Включить автозащиту" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnCheckBypass" Content="Проверить обход" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnTray" Content="Запустить трей" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnTrayAutostart" Content="Автозапуск трея" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock x:Name="txtTrayAutostartState" Text="" Foreground="#75849C" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap" />
                  <TextBlock Text="Автозащита проверяет эндпоинты каждые 4 часа; после двух подряд сбояв запускает автоподбор и переключает службу только на полностью подтверждённую стратегию." Foreground="#75849C" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>

              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.15*" /><ColumnDefinition Width="0.85*" /></Grid.ColumnDefinitions>
                <Border Grid.Column="0" Style="{StaticResource CardBorder}" Margin="0,0,14,14">
                  <StackPanel>
                    <TextBlock Text="Для начала" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                    <TextBlock Text="Если служба ещё не настроена, запустите автонастройку. Она проверит подключение и покажет результат перед применением." Foreground="#A6B3C6" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0" />
                  </StackPanel>
                </Border>
                <Border Grid.Column="1" Style="{StaticResource CardBorder}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Недавние действия" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                    <TextBox x:Name="txtActivity" Text="Приложение готово." IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="#9FADC2" FontSize="11" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="68" Margin="0,8,0,0" />
                  </StackPanel>
                </Border>
              </Grid>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Grid x:Name="pageStrategies" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Выбор стратегии" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Выберите стратегию из списка и установите её службой или запустите вручную. Все действия выполняются здесь же, в окне приложения." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <TextBlock Text="СТРАТЕГИЯ" Style="{StaticResource SmallLabel}" />
                  <ComboBox x:Name="cmbStrategyList" Height="40" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="13" />
                  <TextBox x:Name="txtStrategyInfo" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="64" Margin="0,12,0,14" Padding="12" Background="#0D1627" Foreground="#9FADC2" BorderBrush="#2A3953" FontFamily="Consolas" FontSize="11" />
                  <WrapPanel>
                    <Button x:Name="btnInstallStrategy" Content="Установить службой" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnRunStrategy" Content="Запустить сейчас (ручной)" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnStopRun" Content="Остановить ручной запуск" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnStrategyTest" Content="Тест стратегий (консоль)" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock Text="«Установить» переключает службу на выбранную стратегию. «Запустить сейчас» — временный ручной режим до нажатия «Остановить» или перезагрузки." Foreground="#75849C" FontSize="11" Margin="0,14,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Своя стратегия" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Создайте копию встроенной стратегии и настройте её параметры, импортируйте стратегию по коду zapret1:... или поделитесь своей." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,15" />
                  <WrapPanel>
                    <Button x:Name="btnStrategyClone" Content="Создать копию" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnStrategyImport" Content="Импорт по коду" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnStrategyExport" Content="Экспорт кодом" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="btnEditRepeats" Content="Повторы (repeats)" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnEditSplitPos" Content="Позиция разделения" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnEditSeqovl" Content="Перекрытие сегментов" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnEditStrategyFake" Content="Фейк стратегии" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock Text="Параметры применяются к выбранной пользовательской стратегии (созданной копии или импортированной)." Foreground="#75849C" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Grid x:Name="pageNetwork" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="DNS и защищённый DNS (DoH)" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Если провайдер подменяет обычные DNS-ответы, защищённый DNS может помочь. Все изменения обратимы." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,15" />
                  <WrapPanel>
                    <Button x:Name="btnDnsShow" Content="Показать DNS адаптеров" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDnsDhcp" Content="Вернуть DNS (DHCP)" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDnsRollback" Content="Восстановить DNS из копии" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <WrapPanel Margin="0,10,0,0">
                    <ComboBox x:Name="cmbDohProvider" Width="215" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="13">
                      <ComboBoxItem Content="Cloudflare (1.1.1.1)" IsSelected="True" />
                      <ComboBoxItem Content="Google (8.8.8.8)" />
                      <ComboBoxItem Content="Quad9 (9.9.9.9)" />
                      <ComboBoxItem Content="AdGuard (94.140.14.14)" />
                      <ComboBoxItem Content="Яндекс (77.88.8.8)" />
                    </ComboBox>
                    <Button x:Name="btnDohApply" Content="Включить DoH + DNS" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Сеть и качество соединения" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Инструменты из консольного меню — теперь с журналом в окне приложения." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,15" />
                  <WrapPanel>
                    <Button x:Name="btnDnsBenchmark" Content="Сравнить DNS-провайдеры" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnNetOptimize" Content="Снизить задержку" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnNetRevert" Content="Отменить изменение сети" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnMtuCheck" Content="Проверить MTU" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnPingTest" Content="Качество связи" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Игровой трафик" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtGameFilterState" Text="—" Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,13" />
                  <WrapPanel>
                    <ComboBox x:Name="cmbGameFilter" Width="215" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="13">
                      <ComboBoxItem Content="Выключен" IsSelected="True" />
                      <ComboBoxItem Content="TCP и UDP" />
                      <ComboBoxItem Content="Только TCP" />
                      <ComboBoxItem Content="Только UDP" />
                    </ComboBox>
                    <Button x:Name="btnGameFilterApply" Content="Применить" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" />
                    <Button x:Name="btnGameTcp" Content="Порты TCP" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" />
                    <Button x:Name="btnGameUdp" Content="Порты UDP" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock Text="После изменения режима или портов служба перезапускается — панель предупредит о конфликтах и проверит запуск." Foreground="#75849C" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Grid x:Name="pageSites" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Рекомендации сайтов" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Выберите сервис, просмотрите список доменов и подтвердите добавление. До подтверждения личные списки не меняются." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <TextBlock Text="СЕРВИС" Style="{StaticResource SmallLabel}" />
                  <ComboBox x:Name="cmbRecommendation" Height="40" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="13" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Профиль обхода" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Ограничьте обход выбранными сервисами: домены остальных сервисов из встроенного каталога временно исключаются из обхода. Ваши собственные записи сохраняются; профиль «Все сервисы» возвращает исходное поведение." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,12" />
                  <WrapPanel>
                    <ComboBox x:Name="cmbProfile" Width="270" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="13" />
                    <Button x:Name="btnProfileApply" Content="Применить профиль" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" />
                  </WrapPanel>
                  <TextBlock x:Name="txtProfileState" Text="" Foreground="#75849C" FontSize="11" Margin="0,10,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Проверка сайта" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Проверьте, как сайт проходит через обход: попадает ли домен в списки, отвечает ли сервер и скачиваются ли данные. Введите адрес (например, https://store.steampowered.com или discord.com)." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,12" />
                  <WrapPanel>
                    <TextBox x:Name="txtSiteCheckInput" Width="320" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,7" FontSize="13" VerticalContentAlignment="Center" />
                    <Button x:Name="btnSiteCheck" Content="Проверить" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" IsDefault="True" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Домены для выбранного сервиса" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBox x:Name="txtSiteDomains" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="235" Margin="0,13,0,9" Padding="13" Background="#0D1627" Foreground="#C7D7ED" BorderBrush="#2A3953" FontFamily="Consolas" FontSize="12" />
                  <TextBlock x:Name="txtSiteNote" Text="" TextWrapping="Wrap" Foreground="#91A0B8" FontSize="11" Margin="0,0,0,15" />
                  <Button x:Name="btnAddRecommendation" Content="Добавить выбранный сервис" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left" Margin="0" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Ручное управление доменами" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Добавляйте, исключайте и удаляйте домены вручную — как в консольном меню." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,13" />
                  <TextBox x:Name="txtDomainInput" Height="38" Padding="12,8" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" FontSize="13" VerticalContentAlignment="Center" />
                  <WrapPanel Margin="0,11,0,0">
                    <Button x:Name="btnDomainAdd" Content="Добавить в обход" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnDomainExclude" Content="Исключить из обхода" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDomainRemove" Content="Удалить из списков" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="btnDomainShow" Content="Показать мои списки" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDomainNotepad" Content="Открыть в Блокноте" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDomainReset" Content="Сбросить мои списки" Style="{StaticResource DangerButton}" />
                    <Button x:Name="btnDomainDiscover" Content="Найти домены в DNS-кэше" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <TextBlock Text="«Найти домены» запускает интерактивный сбор в консоли: откройте сайт или игру в браузере, затем вернитесь в консоль." Foreground="#75849C" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="18" Margin="0,0,0,10" Background="#172238">
                <TextBlock Text="Важно: добавление доменов не гарантирует доступность сайта или приложения." TextWrapping="Wrap" Foreground="#B7C5D9" FontSize="11" />
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Grid x:Name="pageMore" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Диагностика и поддержка" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Проверки выполняются в окне приложения — результат в журнале действий." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,18" />
                  <WrapPanel>
                    <Button x:Name="btnDiagnostics" Content="Диагностика" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnDoctor" Content="Проверка установки" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnDoctorFix" Content="Проверка + ремонт" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnVoiceCheck" Content="Голос Discord: проверка и ремонт" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnVoiceNextFake" Content="Сменить фейк голоса (пинг 5000)" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnSupportBundle" Content="Отчёт для поддержки" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnCheckUpdates" Content="Проверить обновления" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnToggleUpdates" Content="Автопроверка обновлений" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnToggleAutoInstall" Content="Автоустановка обновлений" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Списки, IP-фильтр и файлы подмены" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtMoreState" Text="—" Foreground="#91A0B8" FontSize="11" TextWrapping="Wrap" Margin="0,7,0,13" />
                  <WrapPanel>
                    <Button x:Name="btnIpsetLoaded" Content="IPSet: список" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnIpsetNone" Content="IPSet: выкл" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnIpsetAny" Content="IPSet: все адреса" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnIpsetUpdate" Content="Обновить список IP" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnHostsUpdate" Content="Обновить hosts" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <WrapPanel Margin="0,10,0,0">
                    <ComboBox x:Name="cmbFakesDiscord" Width="215" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="12" />
                    <Button x:Name="btnFakeDiscordApply" Content="Фейк для Discord" Style="{StaticResource PrimaryButton}" Margin="10,0,0,0" />
                    <ComboBox x:Name="cmbFakesGame" Width="215" Height="38" Background="#0D1627" Foreground="#E8EEF8" BorderBrush="#2A3953" Padding="8,5" FontSize="12" Margin="10,0,0,0" />
                    <Button x:Name="btnFakeGameApply" Content="Фейк для игр" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Обслуживание" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <WrapPanel>
                    <Button x:Name="btnPause" Content="Пауза обхода" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnRollback" Content="Восстановить из копии" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnImportConfig" Content="Перенести настройки" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnExportConfig" Content="Резервная копия настроек" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnScheduleToggle" Content="Еженедельная перепроверка" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Расширенные действия" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Классическое меню и zapret.bat сохранены как дополнительный способ управления." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,18" />
                  <WrapPanel>
                    <Button x:Name="btnClassicMenu" Content="Открыть классическое меню" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnCreateShortcut" Content="Создать ярлык на рабочем столе" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Удаление" FontSize="16" FontWeight="SemiBold" Foreground="#FFE5E8" />
                  <TextBlock Text="Полностью удалит службы zapret и WinDivert и остановит winws.exe." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,15" />
                  <Button x:Name="btnUninstall" Content="Удалить установку zapret" Style="{StaticResource DangerButton}" HorizontalAlignment="Left" />
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Папки проекта" FontSize="16" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Открывайте журналы, чтобы приложить отчёт к запросу поддержки, или перейдите к файлам установки." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,17" />
                  <WrapPanel>
                    <Button x:Name="btnOpenLogs" Content="Открыть журналы" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnOpenFolder" Content="Открыть папку zapret" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBorder}" Padding="18" Margin="0,0,0,10" Background="#172238">
                <TextBlock Text="Это отдельная панель управления. Она не заменяет zapret.bat и не меняет конфигурацию при запуске." TextWrapping="Wrap" Foreground="#B7C5D9" FontSize="11" />
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <Grid x:Name="pageWizard" Visibility="Collapsed">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border x:Name="wizStepType" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Как подключён этот компьютер?" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Мастер проверит стратегии прямо здесь и применит изменения только после вашего явного согласия." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <WrapPanel>
                    <Button x:Name="btnWizRegular" Content="Обычный — Wi-Fi или кабель" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnWizMobile" Content="Мобильный — SIM/eSIM, модем, точка доступа" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <CheckBox x:Name="chkWizFast" Content="Быстрый подбор — остановиться на первой подходящей стратегии" IsChecked="True" Foreground="#A6B3C6" Margin="0,16,0,0" VerticalContentAlignment="Center" />
                  <Button x:Name="btnWizTypeCancel" Content="Отмена" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left" Margin="0,16,0,0" />
                </StackPanel>
              </Border>
              <Border x:Name="wizStepCarrier" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Выберите оператора текущей SIM/eSIM" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Автоматического определения нет: подключите компьютер именно через эту SIM — USB-модемом или точкой доступа телефона. Профили операторов экспериментальные." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <WrapPanel>
                    <Button x:Name="btnWizMts" Content="МТС" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnWizMegafon" Content="МегаФон" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnWizTele2" Content="Tele2 / T2" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnWizYota" Content="Йота" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                  <Button x:Name="btnWizCarrierBack" Content="Назад" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Left" Margin="0,16,0,0" />
                </StackPanel>
              </Border>
              <Border x:Name="wizStepRun" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock x:Name="txtWizRunTitle" Text="Идёт проверка стратегий…" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtWizRunBody" Text="Это займёт несколько минут: каждый вариант кратко запускается и проверяется на адресах Discord, YouTube и WhatsApp. Не закрывайте окно." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,14" />
                  <Button x:Name="btnWizCancel" Content="Отменить проверку" Style="{StaticResource DangerButton}" HorizontalAlignment="Left" Margin="0,14,0,0" />
                </StackPanel>
              </Border>
                  <RichTextBox x:Name="txtWizLog" IsReadOnly="True" VerticalScrollBarVisibility="Auto" Height="330" Padding="10" Background="#0D1627" Foreground="#C7D7ED" BorderBrush="#2A3953" FontFamily="Consolas" FontSize="11"><FlowDocument PagePadding="0" /></RichTextBox>
              <Border x:Name="wizStepResult" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock x:Name="txtWizResultTitle" Text="Результат" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtWizResultBody" Text="" TextWrapping="Wrap" Foreground="#A6B3C6" FontSize="12" Margin="0,7,0,18" />
                  <WrapPanel>
                    <Button x:Name="btnWizInstall" Content="Установить как службу" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnWizSkip" Content="Не устанавливать" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="btnWizDoh" Content="Включить DoH и повторить" Style="{StaticResource SecondaryButton}" Visibility="Collapsed" />
                    <Button x:Name="btnWizRetry" Content="Повторить проверку" Style="{StaticResource SecondaryButton}" Visibility="Collapsed" />
                    <Button x:Name="btnWizConflicts" Content="Отключить конфликтующие и повторить" Style="{StaticResource SecondaryButton}" Visibility="Collapsed" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border x:Name="wizStepHosts" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Служба установлена" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Обновить управляемый блок hosts и список IPSet? Это необязательно и выполняется только по вашему согласию; действие можно повторить позже из классического меню." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <WrapPanel>
                    <Button x:Name="btnWizHostsYes" Content="Обновить hosts и IPSet" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnWizHostsNo" Content="Пропустить" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border x:Name="wizStepSched" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Еженедельная перепроверка" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock Text="Включить автоматическую перепроверку стратегии по воскресеньям в 03:30? Она выключена по умолчанию и включается только по согласию." Foreground="#91A0B8" FontSize="12" TextWrapping="Wrap" Margin="0,7,0,16" />
                  <WrapPanel>
                    <Button x:Name="btnWizSchedYes" Content="Включить перепроверку" Style="{StaticResource PrimaryButton}" />
                    <Button x:Name="btnWizSchedNo" Content="Не включать" Style="{StaticResource SecondaryButton}" />
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border x:Name="wizStepDone" Visibility="Collapsed" Style="{StaticResource CardBorder}" Padding="23" Margin="0,0,0,15">
                <StackPanel>
                  <TextBlock Text="Готово" FontSize="19" FontWeight="SemiBold" Foreground="#F4F7FC" />
                  <TextBlock x:Name="txtWizDoneBody" Text="Настройка завершена." TextWrapping="Wrap" Foreground="#A6B3C6" FontSize="12" Margin="0,7,0,18" />
                  <Button x:Name="btnWizFinish" Content="Вернуться к управлению" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left" Margin="0" />
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </Grid>
      <TextBlock x:Name="txtToast" Grid.Row="2" Text="Готово" Foreground="#7E8EA8" FontSize="11" VerticalAlignment="Center" />
    </Grid>
  </Grid>
</Window>
'@

try {
    [xml]$xamlDocument = $xamlText
    $xmlReader = New-Object System.Xml.XmlNodeReader($xamlDocument)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()
} catch {
    [void][System.Windows.MessageBox]::Show(("Не удалось построить окно: {0}" -f $_.Exception.Message), 'OpenZapret', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

$script:Window = $window
$script:TxtVersion = $window.FindName('txtVersion')
$script:TxtServiceState = $window.FindName('txtServiceState')
$script:TxtServiceDetail = $window.FindName('txtServiceDetail')
$script:TxtStrategy = $window.FindName('txtStrategy')
$script:TxtIpState = $window.FindName('txtIpState')
$script:TxtActivity = $window.FindName('txtActivity')
$script:TxtToast = $window.FindName('txtToast')
$script:TxtPageTitle = $window.FindName('txtPageTitle')
$script:TxtPageSubtitle = $window.FindName('txtPageSubtitle')
$script:PageHome = $window.FindName('pageHome')
$script:PageSites = $window.FindName('pageSites')
$script:PageMore = $window.FindName('pageMore')
$script:BtnStartService = $window.FindName('btnStartService')
$script:BtnStopService = $window.FindName('btnStopService')
$script:BtnAutoSetup = $window.FindName('btnAutoSetup')
$script:ComboRecommendation = $window.FindName('cmbRecommendation')
$script:TxtSiteDomains = $window.FindName('txtSiteDomains')
$script:TxtSiteNote = $window.FindName('txtSiteNote')
$script:PageWizard = $window.FindName('pageWizard')
$script:WizStepType = $window.FindName('wizStepType')
$script:WizStepCarrier = $window.FindName('wizStepCarrier')
$script:WizStepRun = $window.FindName('wizStepRun')
$script:WizStepResult = $window.FindName('wizStepResult')
$script:WizStepHosts = $window.FindName('wizStepHosts')
$script:WizStepSched = $window.FindName('wizStepSched')
$script:WizStepDone = $window.FindName('wizStepDone')
$script:TxtWizRunTitle = $window.FindName('txtWizRunTitle')
$script:TxtWizLog = $window.FindName('txtWizLog')
$script:TxtWizRunBody = $window.FindName('txtWizRunBody')
$script:TxtWizResultTitle = $window.FindName('txtWizResultTitle')
$script:TxtWizResultBody = $window.FindName('txtWizResultBody')
$script:TxtWizDoneBody = $window.FindName('txtWizDoneBody')
$script:BtnWizInstall = $window.FindName('btnWizInstall')
$script:BtnWizSkip = $window.FindName('btnWizSkip')
$script:BtnWizDoh = $window.FindName('btnWizDoh')
$script:BtnWizRetry = $window.FindName('btnWizRetry')
$script:BtnCheckBypass = $window.FindName('btnCheckBypass')
$script:CmbProfile = $window.FindName('cmbProfile')
$script:BtnProfileApply = $window.FindName('btnProfileApply')
$script:TxtProfileState = $window.FindName('txtProfileState')
$script:TxtSiteCheckInput = $window.FindName('txtSiteCheckInput')
$script:BtnSiteCheck = $window.FindName('btnSiteCheck')
$script:BtnTrayAutostart = $window.FindName('btnTrayAutostart')
$script:TxtTrayAutostartState = $window.FindName('txtTrayAutostartState')
$script:BtnWatchdogToggle = $window.FindName('btnWatchdogToggle')
$script:TxtWatchdogState = $window.FindName('txtWatchdogState')
$script:BtnWizConflicts = $window.FindName('btnWizConflicts')
$script:WizardDohRerun = $false
$script:WizardConflictsMode = ''
$script:ConflictsDisabled = $false
$script:WizardConflictsOffered = $false
$script:WizardFast = $false
$script:BtnBackToWizard = $window.FindName('btnBackToWizard')
$script:BtnWizCancel = $window.FindName('btnWizCancel')
$script:ChkWizFast = $window.FindName('chkWizFast')
$script:PageStrategies = $window.FindName('pageStrategies')
$script:PageNetwork = $window.FindName('pageNetwork')
$script:CmbStrategyList = $window.FindName('cmbStrategyList')
$script:TxtStrategyInfo = $window.FindName('txtStrategyInfo')
$script:CmbDohProvider = $window.FindName('cmbDohProvider')
$script:CmbGameFilter = $window.FindName('cmbGameFilter')
$script:TxtGameFilterState = $window.FindName('txtGameFilterState')
$script:TxtDomainInput = $window.FindName('txtDomainInput')
$script:TxtMoreState = $window.FindName('txtMoreState')
$script:CmbFakesDiscord = $window.FindName('cmbFakesDiscord')
$script:CmbFakesGame = $window.FindName('cmbFakesGame')
$script:TxtWizRunTitle = $window.FindName('txtWizRunTitle')
try {
    $iconFile = Join-Path $script:AppRoot 'Zapret-Control.ico'
    if (Test-Path -LiteralPath $iconFile -PathType Leaf) {
        $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($iconFile)))
    }
} catch { }

function Add-ControlActivity {
    param([Parameter(Mandatory = $true)][string]$Message)
    $entry = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:ActivityEntries.Insert(0, $entry)
    while ($script:ActivityEntries.Count -gt 6) { $script:ActivityEntries.RemoveAt($script:ActivityEntries.Count - 1) }
    $script:TxtActivity.Text = $script:ActivityEntries -join "`r`n"
    $script:TxtToast.Text = $Message
}

function Show-ControlError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Add-ControlActivity -Message ("Ошибка: {0}" -f $Message)
    [void][System.Windows.MessageBox]::Show($script:Window, $Message, 'Не удалось выполнить действие', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}

function Set-ControlPage {
    param([ValidateSet('home','strategies','network','sites','more','wizard')][string]$Page)
    $script:PageHome.Visibility = if ($Page -eq 'home') { 'Visible' } else { 'Collapsed' }
    $script:PageStrategies.Visibility = if ($Page -eq 'strategies') { 'Visible' } else { 'Collapsed' }
    $script:PageNetwork.Visibility = if ($Page -eq 'network') { 'Visible' } else { 'Collapsed' }
    $script:PageSites.Visibility = if ($Page -eq 'sites') { 'Visible' } else { 'Collapsed' }
    $script:PageMore.Visibility = if ($Page -eq 'more') { 'Visible' } else { 'Collapsed' }
    $script:PageWizard.Visibility = if ($Page -eq 'wizard') { 'Visible' } else { 'Collapsed' }
    switch ($Page) {
        'home' { $script:TxtPageTitle.Text = 'Управление zapret'; $script:TxtPageSubtitle.Text = 'Быстрые действия и понятный статус — без консольного меню.' }
        'strategies' { $script:TxtPageTitle.Text = 'Стратегии'; $script:TxtPageSubtitle.Text = 'Выбор, установка и настройка стратегий обхода.' }
        'network' { $script:TxtPageTitle.Text = 'Сеть и DNS'; $script:TxtPageSubtitle.Text = 'DNS, DoH, качество соединения и игровой трафик.' }
        'sites' { $script:TxtPageTitle.Text = 'Мои сайты'; $script:TxtPageSubtitle.Text = 'Рекомендации и ручное управление доменами.' }
        'more' { $script:TxtPageTitle.Text = 'Дополнительно'; $script:TxtPageSubtitle.Text = 'Диагностика, списки, обслуживание и удаление.' }
        'wizard' { $script:TxtPageTitle.Text = 'Выполнение действия'; $script:TxtPageSubtitle.Text = 'Всё выполняется в окне приложения — следите за журналом.' }
    }
}

function Update-TrayAutostartCard {
    try {
        if (-not $script:TxtTrayAutostartState) { return }
        $state = Get-TrayAutostartState
        $script:TxtTrayAutostartState.Text = if ($state.Enabled) { 'Автозапуск трея включён: значок появится при входе в Windows.' } else { 'Автозапуск трея выключен.' }
        if ($script:BtnTrayAutostart) {
            $script:BtnTrayAutostart.Content = if ($state.Enabled) { 'Выключить автозапуск трея' } else { 'Включить автозапуск трея' }
        }
    } catch {
        if ($script:TxtTrayAutostartState) { $script:TxtTrayAutostartState.Text = 'Автозапуск трея: состояние недоступно.' }
    }
}

function Update-ProfileCard {
    try {
        $current = Get-BypassProfile
        $label = $current
        foreach ($p in (Get-BypassProfiles)) { if ($p.Id -eq $current) { $label = [string]$p.NameRu } }
        if ($script:TxtProfileState) {
            $note = 'Текущий профиль: ' + $label + '.'
            if ($current -ne 'all') {
                $note += ' Узкий профиль использует встроенный каталог доменов-подсказок; отдельные CDN-адреса сервисов могут не попасть в список.'
            }
            $script:TxtProfileState.Text = $note
        }
    } catch { }
}

function Update-WatchdogCard {
    try {
        $state = Get-WatchdogState
        $enabled = Test-WatchdogSchedule
        $lines = New-Object 'System.Collections.Generic.List[string]'
        if ($enabled) {
            $lines.Add('Автозащита включена: проверка каждые 4 часа, автовосстановление после двух подряд сбоёв.')
        } else {
            $lines.Add('Автозащита выключена.')
        }
        if ([string]$state.LastCheckUtc) {
            $lines.Add(('Последняя проверка: {0} — {1}.' -f $state.LastCheckUtc, $state.LastResult))
        }
        if ([string]$state.LastAction -and [string]$state.LastAction -ne 'ok') {
            $lines.Add(('Последнее действие: {0}.' -f $state.LastAction))
        }
        $lines.Add((Get-StrategyFallbackStatusText))
        if ($script:TxtWatchdogState) { $script:TxtWatchdogState.Text = ($lines -join ' ') }
        if ($script:BtnWatchdogToggle) {
            $script:BtnWatchdogToggle.Content = if ($enabled) { 'Выключить автозащиту' } else { 'Включить автозащиту' }
        }
    } catch { }
}

function Refresh-ControlStatus {
    try {
        $service = Get-ZapretServiceInfo
        $script:CurrentServiceInfo = $service
        $ownRun = $false
        try {
            $ownBin = [string](Get-ZapretBinDir)
            foreach ($wp in @(Get-WinwsProcess)) {
                $wpPath = $null
                try { $wpPath = [string]$wp.Path } catch { }
                if (-not $wpPath -or ($ownBin -and $wpPath.StartsWith($ownBin, [StringComparison]::OrdinalIgnoreCase))) { $ownRun = $true; break }
            }
        } catch { }
        if ($service.Installed) {
            switch -Exact ([string]$service.State) {
                'Running' {
                    $script:TxtServiceState.Text = 'Работает'
                    $script:TxtServiceState.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#51D6A5')
                    $script:TxtServiceDetail.Text = 'Служба установлена и запущена.'
                    $script:BtnStartService.IsEnabled = $false
                    $script:BtnStopService.IsEnabled = $true
                }
                'Stopped' {
                    $script:TxtServiceState.Text = 'Остановлена'
                    $script:TxtServiceState.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5B95F')
                    $script:TxtServiceDetail.Text = if ($ownRun) { 'Служба остановлена, но winws.exe этой установки ещё работает.' } else { 'Служба установлена, но сейчас не запущена.' }
                    $script:BtnStartService.IsEnabled = $true
                    $script:BtnStopService.IsEnabled = [bool]$ownRun
                }
                default {
                    $script:TxtServiceState.Text = [string]$service.State
                    $script:TxtServiceState.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5B95F')
                    $script:TxtServiceDetail.Text = 'Служба меняет состояние.'
                    $script:BtnStartService.IsEnabled = $false
                    $script:BtnStopService.IsEnabled = $false
                }
            }
            $strategyLabel = [string]$service.Strategy
            if ($service.Strategy) {
                try {
                    $strategy = Get-Strategy -Id ([string]$service.Strategy)
                    if ($strategy) { $strategyLabel = '{0}  ·  {1}' -f $strategy.name, $strategy.id }
                } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($strategyLabel)) { $strategyLabel = 'Не определена' }
            $script:TxtStrategy.Text = $strategyLabel
        } elseif ($service.WinwsRunning) {
            $script:TxtServiceState.Text = 'Ручной запуск'
            $script:TxtServiceState.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5B95F')
            if ($ownRun) {
                $script:TxtServiceDetail.Text = 'Обход запущен вручную (winws.exe этой установки). Кнопка «Остановить» выключит его.'
            } else {
                $script:TxtServiceDetail.Text = 'Обнаружен winws.exe другой установки. Панель не останавливает чужие процессы.'
            }
            $script:TxtStrategy.Text = 'Служба не установлена'
            $script:BtnStartService.IsEnabled = $false
            $script:BtnStopService.IsEnabled = [bool]$ownRun
        } else {
            $script:TxtServiceState.Text = 'Не настроена'
            $script:TxtServiceState.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#91A0B8')
            $script:TxtServiceDetail.Text = 'Запустите автонастройку, чтобы проверить варианты.'
            $script:TxtStrategy.Text = '—'
            $script:BtnStartService.IsEnabled = $false
            $script:BtnStopService.IsEnabled = $false
        }

        $ipset = Get-IpsetState
        $ipsetLabel = switch ([string]$ipset) {
            'loaded' { 'Список загружен' }
            'none' { 'Выключен' }
            'any' { 'Все адреса' }
            default { 'Неизвестно' }
        }
        $script:TxtIpState.Text = $ipsetLabel
        try { $script:TxtVersion.Text = 'Версия ' + (Get-LocalVersion) } catch { $script:TxtVersion.Text = 'OpenZapret' }
        try { Update-ControlPageState } catch { }
        try { Update-WatchdogCard } catch { }
        try { Update-ProfileCard } catch { }
        try { Update-TrayAutostartCard } catch { }
        $script:TxtToast.Text = 'Статус обновлён: ' + (Get-Date -Format 'HH:mm:ss')
    } catch {
        $script:TxtServiceState.Text = 'Нет данных'
        $script:TxtServiceDetail.Text = $_.Exception.Message
        $script:TxtToast.Text = 'Не удалось прочитать состояние.'
        Add-ControlActivity -Message ("Ошибка чтения состояния: {0}" -f $_.Exception.Message)
    }
}

function Start-ControlConsoleAction {
    param([Parameter(Mandatory = $true)][ValidateSet('auto-setup','diagnostics')][string]$Action)
    if (-not (Test-Path -LiteralPath $script:CliPath -PathType Leaf)) { throw 'Не найден zapret.ps1.' }
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script:CliPath, $Action
    Start-Process -FilePath $script:PowerShellExe -ArgumentList $arguments -WorkingDirectory $script:AppRoot -WindowStyle Normal | Out-Null
    $message = if ($Action -eq 'auto-setup') { 'Открыт мастер автонастройки.' } else { 'Открыта диагностика.' }
    Add-ControlActivity -Message $message
}

$script:WizardWinner = $null
$script:WizardAutoInstalled = $false
$script:WizardCarrier = $null
$script:WizardBusy = $false
$script:WizardMode = 'benchmark'
$script:WizardInfoIndex = 0
$script:WizardWarnIndex = 0
$script:WizardErrIndex = 0

function Set-WizardStep {
    param([ValidateSet('type','carrier','run','result','hosts','sched','done')][string]$Step)
    $script:WizStepType.Visibility = if ($Step -eq 'type') { 'Visible' } else { 'Collapsed' }
    $script:WizStepCarrier.Visibility = if ($Step -eq 'carrier') { 'Visible' } else { 'Collapsed' }
    $script:WizStepRun.Visibility = if ($Step -eq 'run') { 'Visible' } else { 'Collapsed' }
    $script:WizStepResult.Visibility = if ($Step -eq 'result') { 'Visible' } else { 'Collapsed' }
    $script:WizStepHosts.Visibility = if ($Step -eq 'hosts') { 'Visible' } else { 'Collapsed' }
    $script:WizStepSched.Visibility = if ($Step -eq 'sched') { 'Visible' } else { 'Collapsed' }
    $script:WizStepDone.Visibility = if ($Step -eq 'done') { 'Visible' } else { 'Collapsed' }
    $script:TxtWizLog.Visibility = if ($Step -in @('run','result')) { 'Visible' } else { 'Collapsed' }
}

function Update-WizardChrome {
    # The action page is not part of the sidebar; while a background action is
    # running every page offers a way back to it instead of "losing" the run.
    $script:BtnBackToWizard.Visibility = if ($script:WizardBusy) { 'Visible' } else { 'Collapsed' }
}

function Stop-WizardRun {
    if (-not $script:WizardBusy -or $null -eq $script:WizardPs) { return }
    # A run that already finished keeps its result; the pending tick will
    # deliver it. Cancelling now would only swap the outcome for a lie.
    if ($script:WizardAsync -and $script:WizardAsync.IsCompleted) { return }
    $script:WizardCancelled = $true
    try { $script:WizardPs.Stop() } catch { }
    try { [void](Stop-Zapret) } catch { }
    Add-WizardLog '[!] Останавливаю проверку…'
}

function Complete-WizardDone {
    # The done step must never show a stale or misleading summary: the wizard
    # reaches it from the install path as well as from the skip path.
    if ($script:WizardAutoInstalled) {
        $name = ''
        if ($script:WizardWinner -and $script:WizardWinner.PSObject.Properties['Id']) { $name = [string]$script:WizardWinner.Id }
        if ($name) {
            $script:TxtWizDoneBody.Text = ('Готово. Стратегия {0} установлена в автозапуск и запущена. Мастер можно запустить снова в любой момент.' -f $name)
        } else {
            $script:TxtWizDoneBody.Text = 'Готово. Служба установлена и запущена. Мастер можно запустить снова в любой момент.'
        }
    } else {
        $script:TxtWizDoneBody.Text = 'Проверенный вариант не установлен; ничего не изменено. Мастер можно запустить снова в любой момент.'
    }
}

function Complete-WizardCancelled {
    $extraDoh = Get-Variable -Name BtnWizDoh -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $extraRetry = Get-Variable -Name BtnWizRetry -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraDoh) { $extraDoh.Visibility = 'Collapsed' }
    if ($extraRetry) { $extraRetry.Visibility = 'Collapsed' }
    $extraConf = Get-Variable -Name BtnWizConflicts -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraConf) {
        if ([bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $extraConf.Content = 'Включить отключённые обратно'
            $extraConf.Visibility = 'Visible'
        } else {
            $extraConf.Visibility = 'Collapsed'
        }
    }
    $script:WizardCancelled = $false
    $script:TxtWizResultTitle.Text = 'Проверка отменена'
    $script:TxtWizResultBody.Text = 'Вы остановили проверку. Ничего не изменено: служба, hosts/IPSet и DNS не тронуты. Можно запустить проверку снова.'
    $script:BtnWizInstall.Visibility = 'Collapsed'
    $script:BtnWizSkip.Content = 'Готово'
    Update-WizardChrome
    Set-WizardStep -Step 'result'
}

function Choose-WizardLogColor {
    param([string]$Line, [string]$LogColorName = '')
    $map = @{
        Green = '#51D6A5'
        DarkGreen = '#51D6A5'
        Red = '#F28B82'
        DarkRed = '#F28B82'
        Yellow = '#F5B95F'
        DarkYellow = '#F5B95F'
        Gray = '#75849C'
        DarkGray = '#75849C'
        Cyan = '#7FD6F5'
        White = '#E8EEF8'
        Magenta = '#C792EA'
    }
    if ($LogColorName -and $map.ContainsKey($LogColorName)) { return $map[$LogColorName] }
    if ($Line -match '^\[x\]') { return $map.Red }
    if ($Line -match '^\[!\]') { return $map.Yellow }
    if ($Line -match 'HTTP\s+[45]\d\d' -or $Line -like '*ответа нет*' -or $Line -like '*тайм-аут*') { return $map.Red }
    if ($Line -match 'HTTP\s+[123]\d\d') { return $map.Green }
    return '#C7D7ED'
}

function Add-WizardLog {
    param([string]$Line, [string]$LogColorName = '')
    if ($script:TxtWizLog.PSObject.Properties['Document']) {
        $colorText = Choose-WizardLogColor -Line $Line -LogColorName $LogColorName
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = '0'
        $para.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($colorText)
        [void]$para.Inlines.Add((New-Object System.Windows.Documents.Run($Line)))
        [void]$script:TxtWizLog.Document.Blocks.Add($para)
    } else {
        $script:TxtWizLog.AppendText($Line + "`r`n")
    }
    $script:TxtWizLog.ScrollToEnd()
}

function Clear-WizardLog {
    if ($script:TxtWizLog.PSObject.Properties['Document']) {
        $script:TxtWizLog.Document.Blocks.Clear()
    } else {
        $script:TxtWizLog.Text = ''
    }
}

function Start-WizardBenchmark {
    # Runs the same benchmark as the console master, in a background runspace,
    # streaming its console output into the wizard log. Nothing is installed
    # here: the wizard only measures and reports.
    param([string]$Carrier, [bool]$Fast)
    if ($script:WizardBusy) { return }
    $conflictsOffered = [bool](Get-Variable -Name WizardConflictsOffered -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not $conflictsOffered) {
        $preList = @()
        try {
            $preReport = Get-ZapretConflictReport
            if ($preReport -and $preReport.PSObject.Properties['Items'] -and $null -ne $preReport.Items) { $preList = @($preReport.Items) }
        } catch { $preList = @() }
        if ($preList.Count -gt 0) {
            $script:WizardConflictsOffered = $true
            if (Confirm-ControlAction ('Обнаружены конфликтующие программы: {0}. Отключить их сейчас и запустить проверку? Службы будут остановлены и отключены (это обратимо), конфликтующие процессы будут завершены.' -f ($preList -join ', ')) 'Конфликтующие программы') {
                $script:WizardConflictsMode = 'disable'
                $script:WizardCarrier = $Carrier
                $script:WizardFast = $Fast
                Start-ControlAction -Title 'Конфликты: отключение' -Action {
                    $report = Get-ZapretConflictReport
                    $result = Disable-ZapretConflictPrograms -Report $report
                    foreach ($svc in @($result.Services)) { Write-Host ('Служба отключена: {0}' -f $svc.Name) }
                    foreach ($procName in @($result.Processes)) { Write-Host ('Процесс завершён: {0}' -f $procName) }
                    foreach ($err in @($result.Failed)) { Write-Host ('Не выполнено: {0}' -f $err) -ForegroundColor Yellow }
                    if ($result.BackupPath) { Write-Host ('Прежние настройки служб сохранены: {0}' -f $result.BackupPath) -ForegroundColor DarkGray }
                    Write-Host 'Конфликтующие программы отключены — запускаю проверку стратегий…'
                }
                return
            }
        }
    }
    $script:WizardBusy = $true
    $script:WizardMode = 'benchmark'
    $script:WizardCarrier = $Carrier
    $script:WizardWinner = $null
    $script:WizardAutoInstalled = $false
    $script:WizardInfoIndex = 0
    $script:WizardWarnIndex = 0
    $script:WizardErrIndex = 0
    Clear-WizardLog
    if ($Carrier) {
        $labels = @{ mts = 'МТС'; megafon = 'МегаФон'; tele2 = 'Tele2/T2'; yota = 'Йота' }
        $script:TxtWizRunTitle.Text = ('Проверка профиля оператора: {0}…' -f $labels[[string]$Carrier])
        $script:TxtWizRunBody.Text = 'Это займёт несколько минут: каждый вариант кратко запускается и проверяется на адресах Discord, YouTube и WhatsApp. Не закрывайте окно.'
    } else {
        $script:TxtWizRunTitle.Text = 'Идёт проверка стратегий…'
        $script:TxtWizRunBody.Text = 'Это займёт несколько минут: каждый вариант кратко запускается и проверяется на адресах Discord, YouTube и WhatsApp. Не закрывайте окно.'
    }
    $script:WizardRunBaseTitle = $script:TxtWizRunTitle.Text
    $script:WizardCancelled = $false
    $script:BtnWizCancel.Visibility = 'Visible'
    Update-WizardChrome
    Set-WizardStep -Step 'run'
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $scriptBlock = {
        param($ModulePath, $Carrier, $Fast)
        Import-Module -Name $ModulePath -Force
        if ($Carrier) { Invoke-AutoSelect -NoInteractive -Fast -Carrier $Carrier }
        elseif ($Fast) { Invoke-AutoSelect -NoInteractive -Fast }
        else { Invoke-AutoSelect -NoInteractive }
    }
    [void]$ps.AddScript($scriptBlock.ToString()).AddArgument($script:ModulePath).AddArgument($Carrier).AddArgument([bool]$Fast)
    $script:WizardRunspace = $runspace
    $script:WizardPs = $ps
    $script:WizardAsync = $ps.BeginInvoke()
    $script:WizardTimer.Start()
}

function Start-WizardVoiceCheck {
    # Runs the Discord voice check-and-repair ladder (conflicts, TCP signalling,
    # UDP probes; on failure: bypass restart + voice fake cycling) in a
    # background runspace, streaming its console output into the wizard log.
    param()
    if ($script:WizardBusy) { return }
    $script:WizardBusy = $true
    $script:WizardMode = 'voice'
    $script:WizardInfoIndex = 0
    $script:WizardWarnIndex = 0
    $script:WizardErrIndex = 0
    Clear-WizardLog
    $script:TxtWizRunTitle.Text = 'Проверка и ремонт голосового пути Discord…'
    $script:TxtWizRunBody.Text = 'Проверка выполняется в окне приложения — следите за журналом ниже. Не закрывайте окно.'
    $script:WizardRunBaseTitle = $script:TxtWizRunTitle.Text
    $script:WizardCancelled = $false
    $script:BtnWizCancel.Visibility = 'Visible'
    Update-WizardChrome
    Set-WizardStep -Step 'run'
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $scriptBlock = {
        param($ModulePath)
        Import-Module -Name $ModulePath -Force
        Repair-DiscordVoice
    }
    [void]$ps.AddScript($scriptBlock.ToString()).AddArgument($script:ModulePath)
    $script:WizardRunspace = $runspace
    $script:WizardPs = $ps
    $script:WizardAsync = $ps.BeginInvoke()
    $script:WizardTimer.Start()
}

function Confirm-ControlAction {
    param([string]$Message, [string]$Title = 'Подтверждение')
    $answer = [System.Windows.MessageBox]::Show($script:Window, $Message, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Show-ControlHelp {
    # In-app quick guide; the full manual lives in ИНСТРУКЦИЯ.txt next to the app.
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Инструкция — OpenZapret'
    $dialog.Width = 640
    $dialog.Height = 660
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Owner = $script:Window
    $dialog.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#131D31')
    $dialog.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E8EEF8')
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = '24'
    $sections = @(
        @{ Title = 'Быстрый старт'; Body = 'Откройте «Автонастройку» и следуйте мастеру: тип подключения, оператор, проверка стратегий. Когда подбор закончится, лучший вариант вставляется в автозапуск и запускается автоматически.' },
        @{ Title = 'Журнал проверки'; Body = 'Каждый адрес выводится одной строкой. Зелёным показаны прошедшие проверки (HTTP 2xx/3xx), красным — проблемные (ошибка, тайм-аут, HTTP 4xx/5xx), жёлтым — предупреждения.' },
        @{ Title = 'Отмена и возврат'; Body = 'Во время проверок доступна кнопка «Отменить проверку». Если вы переключились на другую страницу, «Вернуться к действию» вернёт на экран выполнения. Установку службы и другие изменяющие действия отменить нельзя.' },
        @{ Title = 'Ручной запуск'; Body = 'Вкладка «Стратегии» → «Запустить сейчас (ручной)» запускает обход и показывает статус в журнале. Если winws.exe не стартует, панель показывает причину и сама чинит устаревшую службу WinDivert.' },
        @{ Title = 'Если что-то не работает'; Body = 'Раздел «Дополнительно» → «Диагностика» собирает данные о системе, «Отчёт для поддержки» готовит информацию для обращения. Кнопка «Обновить статус» в шапке обновляет состояние службы.' },
        @{ Title = 'Служба и автозапуск'; Body = 'Установка в автозапуск выполняется из мастера. Управление — на главной странице: запустить, остановить или удалить службу.' }
    )
    foreach ($s in $sections) {
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $s.Title
        $title.FontSize = 15
        $title.FontWeight = 'SemiBold'
        $title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F4F7FC')
        $title.Margin = '0,0,0,4'
        [void]$stack.Children.Add($title)
        $body = New-Object System.Windows.Controls.TextBlock
        $body.Text = $s.Body
        $body.TextWrapping = 'Wrap'
        $body.FontSize = 12
        $body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6B3C6')
        $body.Margin = '0,0,0,16'
        [void]$stack.Children.Add($body)
    }
    $close = New-Object System.Windows.Controls.Button
    $close.Content = 'Закрыть'
    $close.Width = 110
    $close.Height = 32
    $close.HorizontalAlignment = 'Right'
    $close.Add_Click({ $dialog.Close() })
    [void]$stack.Children.Add($close)
    $scroll.Content = $stack
    $dialog.Content = $scroll
    [void]$dialog.ShowDialog()
}

function Show-ControlInputDialog {
    # Small modal input used instead of console Read-Host prompts.
    param([string]$Title = 'Ввод', [string]$Message = '', [string]$DefaultValue = '')
    $dialog = New-Object System.Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 480
    $dialog.Height = 230
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Owner = $script:Window
    $dialog.ResizeMode = 'NoResize'
    $dialog.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#131D31')
    $dialog.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E8EEF8')
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '22'
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Message
    $label.TextWrapping = 'Wrap'
    $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6B3C6')
    $label.Margin = '0,0,0,10'
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $DefaultValue
    $box.Height = 34
    $box.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0D1627')
    $box.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E8EEF8')
    $box.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2A3953')
    $box.FontSize = 13
    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = '0,18,0,0'
    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = 'OK'
    $ok.Width = 88
    $ok.Height = 32
    $ok.Margin = '0,0,10,0'
    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = 'Отмена'
    $cancel.Width = 88
    $cancel.Height = 32
    [void]$buttons.Children.Add($ok)
    [void]$buttons.Children.Add($cancel)
    [void]$panel.Children.Add($label)
    [void]$panel.Children.Add($box)
    [void]$panel.Children.Add($buttons)
    $dialog.Content = $panel
    $ok.Add_Click({ $dialog.DialogResult = $true })
    $cancel.Add_Click({ $dialog.DialogResult = $false })
    $box.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Enter') { $dialog.DialogResult = $true } })
    [void]$dialog.ShowDialog()
    if ($dialog.DialogResult) { return [string]$box.Text }
    return $null
}

function Start-ControlAction {
    # Runs a module action in a background runspace and streams its console
    # output into the shared log page - the in-app replacement for the console
    # menu. The runspace enables non-interactive mode so prompts cannot hang.
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [object[]]$ArgumentList = @()
    )
    if ($script:WizardBusy) {
        Add-ControlActivity -Message 'Другое действие ещё выполняется — дождитесь завершения.'
        return
    }
    $script:WizardBusy = $true
    $script:WizardMode = 'action'
    $script:WizardInfoIndex = 0
    $script:WizardWarnIndex = 0
    $script:WizardErrIndex = 0
    Clear-WizardLog
    $script:TxtWizRunTitle.Text = ($Title + '…')
    $script:TxtWizRunBody.Text = 'Действие выполняется в окне приложения — результаты появятся в журнале ниже. Не закрывайте окно.'
    $script:WizardRunBaseTitle = $script:TxtWizRunTitle.Text
    $script:WizardCancelled = $false
    # Mutating actions must not be cancelled half-way (a stopped install leaves
    # a broken state), so the cancel button stays hidden for them.
    $script:BtnWizCancel.Visibility = 'Collapsed'
    Update-WizardChrome
    Set-WizardStep -Step 'run'
    Set-ControlPage -Page 'wizard'
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $scriptBlock = {
        param($ModulePath, $ActionText, $ActionArgs)
        Import-Module -Name $ModulePath -Force
        Set-ZapretNonInteractive $true
        $inner = [scriptblock]::Create($ActionText)
        & $inner @ActionArgs
    }
    [void]$ps.AddScript($scriptBlock.ToString()).AddArgument($script:ModulePath).AddArgument($Action.ToString()).AddArgument([object[]]$ArgumentList)
    $script:WizardRunspace = $runspace
    $script:WizardPs = $ps
    $script:WizardAsync = $ps.BeginInvoke()
    $script:WizardTimer.Start()
}

function Complete-ControlAction {
    param([bool]$Failed = $false)
    $dohRerun = [bool](Get-Variable -Name WizardDohRerun -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($dohRerun) {
        $script:WizardDohRerun = $false
        if (-not $Failed -and (Get-Command Start-WizardBenchmark -ErrorAction SilentlyContinue)) {
            Start-WizardBenchmark -Carrier $script:WizardCarrier -Fast $script:WizardFast
            return
        }
    }
    $conflictsMode = [string](Get-Variable -Name WizardConflictsMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($conflictsMode) {
        $script:WizardConflictsMode = ''
        if ($conflictsMode -eq 'disable') {
            if (-not $Failed) {
                $script:ConflictsDisabled = $true
                if (Get-Command Start-WizardBenchmark -ErrorAction SilentlyContinue) {
                    Start-WizardBenchmark -Carrier $script:WizardCarrier -Fast $script:WizardFast
                    return
                }
            }
        } elseif ($conflictsMode -eq 'restore') {
            $script:ConflictsDisabled = $false
        }
    }
    $extraDoh = Get-Variable -Name BtnWizDoh -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $extraRetry = Get-Variable -Name BtnWizRetry -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraDoh) { $extraDoh.Visibility = 'Collapsed' }
    if ($extraRetry) { $extraRetry.Visibility = 'Collapsed' }
    $extraConf = Get-Variable -Name BtnWizConflicts -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraConf) {
        if ([bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $extraConf.Content = 'Включить отключённые обратно'
            $extraConf.Visibility = 'Visible'
        } else {
            $extraConf.Content = 'Отключить конфликтующие и повторить'
            $extraConf.Visibility = 'Collapsed'
        }
    }
    if ($Failed) {
        $script:TxtWizResultTitle.Text = 'Действие завершено с ошибками'
        $script:TxtWizResultBody.Text = 'Часть операций не выполнена — подробности в журнале выше.'
    } else {
        $script:TxtWizResultTitle.Text = 'Готово'
        $script:TxtWizResultBody.Text = 'Действие выполнено. Журнал выше содержит все подробности.'
    }
    $script:BtnWizInstall.Visibility = 'Collapsed'
    $script:BtnWizSkip.Content = 'Готово'
    try { Refresh-ControlStatus } catch { }
    Set-WizardStep -Step 'result'
}

function Update-ControlPageState {
    # Fills the slower-changing page state: strategy list, fakes, game filter,
    # schedule and update toggles. Failures never break the main status.
    try {
        $strategies = @(Get-Strategies)
        if ($script:CmbStrategyList.Items.Count -ne $strategies.Count) {
            $script:CmbStrategyList.ItemsSource = $strategies
            $script:CmbStrategyList.DisplayMemberPath = 'name'
            if ($strategies.Count -gt 0) { $script:CmbStrategyList.SelectedIndex = 0 }
        }
        $sel = $script:CmbStrategyList.SelectedItem
        if ($sel) {
            $info = ('ID: {0}    Имя: {1}' -f $sel.id, $sel.name)
            if ($sel.args) { $info += ("`r`n" + [string]$sel.args) }
            $script:TxtStrategyInfo.Text = $info
        }
    } catch { }
    $rbText = 'копий пока нет'
    $cfg = $null
    try { $cfg = Get-Config } catch { }
    if ($cfg) {
        try {
            $modeIndex = switch ([string]$cfg.gameFilter.mode) {
                'disabled' { 0 }
                'all' { 1 }
                'tcp' { 2 }
                'udp' { 3 }
                default { 0 }
            }
            if ($script:CmbGameFilter -and $null -ne $script:CmbGameFilter.SelectedIndex -and $script:CmbGameFilter.SelectedIndex -ne $modeIndex) { $script:CmbGameFilter.SelectedIndex = $modeIndex }
            if ($script:TxtGameFilterState) { $script:TxtGameFilterState.Text = ('Сейчас: {0}   ·   порты TCP: {1}   ·   порты UDP: {2}' -f @('выключен','TCP и UDP','только TCP','только UDP')[$modeIndex], $cfg.gameFilter.tcp, $cfg.gameFilter.udp) }
        } catch { }
        try {
            $updatesText = if ($cfg.checkUpdates) { 'включена' } else { 'выключена' }
            if ($script:BtnToggleUpdates) { $script:BtnToggleUpdates.Content = ('Автопроверка: {0}' -f $updatesText) }
            $autoInstallText = if ($cfg.autoInstallUpdates) { 'включена' } else { 'выключена' }
            if ($script:BtnToggleAutoInstall) { $script:BtnToggleAutoInstall.Content = ('Автоустановка: {0}' -f $autoInstallText) }
        } catch { }
        try {
            $schedOn = $false
            try { $schedOn = [bool](Test-AutoSelectSchedule) } catch { }
            if ($script:BtnScheduleToggle) { $script:BtnScheduleToggle.Content = if ($schedOn) { 'Перепроверка: вкл — выключить' } else { 'Перепроверка: выкл — включить' } }
            $rb = $cfg.rollback
            $rbText = if ($rb -and $rb.folder) { ('копия от {0} ({1})' -f $rb.time, $rb.reason) } else { 'копий пока нет' }
        } catch { }
    } else {
        try {
            if ($script:BtnToggleUpdates) { $script:BtnToggleUpdates.Content = 'Автопроверка: включена' }
            if ($script:BtnToggleAutoInstall) { $script:BtnToggleAutoInstall.Content = 'Автоустановка: выключена' }
        } catch { }
    }
    $fakesText = 'фейки не определены'
    try {
        $inv = Get-FakeInventory
        $fakesText = ('фейк Discord: {0}   ·   фейк игр: {1}' -f $inv.CurrentDiscordFake, $inv.CurrentGameFake)
        $fakeItems = @($inv.Fakes | ForEach-Object { [pscustomobject]@{ BaseName = [string]$_.BaseName; FullName = [string]$_.FullName } })
        if ($script:CmbFakesDiscord.Items.Count -ne $fakeItems.Count) {
            $script:CmbFakesDiscord.ItemsSource = $fakeItems
            $script:CmbFakesDiscord.DisplayMemberPath = 'BaseName'
            $script:CmbFakesGame.ItemsSource = $fakeItems
            $script:CmbFakesGame.DisplayMemberPath = 'BaseName'
        }
    } catch { }
    $script:TxtMoreState.Text = ('{0}   ·   откат: {1}' -f $fakesText, $rbText)
}

function Update-WizardProgress {
    if ($null -eq $script:WizardPs) { return }
    try {
        $info = $script:WizardPs.Streams.Information
        while ($script:WizardInfoIndex -lt $info.Count) {
            $msgData = $info[$script:WizardInfoIndex].MessageData
            $line = [string]$msgData
            $logColorName = ''
            if ($msgData -and $msgData.PSObject.Properties['ForegroundColor']) {
                $logColorName = [string]$msgData.ForegroundColor
                if ($msgData.PSObject.Properties['Message'] -and $msgData.Message) { $line = [string]$msgData.Message }
            }
            Add-WizardLog -Line $line -LogColorName $logColorName
            if ($line -match '^\[\s*(\d+)/(\d+)\]' -and $script:WizardRunBaseTitle) {
                $script:TxtWizRunTitle.Text = ('{0} {1}/{2}' -f $script:WizardRunBaseTitle, $Matches[1], $Matches[2])
            }
            $script:WizardInfoIndex++
        }
        $warnings = $script:WizardPs.Streams.Warning
        while ($script:WizardWarnIndex -lt $warnings.Count) {
            Add-WizardLog ('[!] ' + [string]$warnings[$script:WizardWarnIndex].Message)
            $script:WizardWarnIndex++
        }
        $errors = $script:WizardPs.Streams.Error
        while ($script:WizardErrIndex -lt $errors.Count) {
            Add-WizardLog ('[x] ' + [string]$errors[$script:WizardErrIndex].Exception.Message)
            $script:WizardErrIndex++
        }
        if (-not $script:WizardAsync.IsCompleted) { return }
        $script:WizardTimer.Stop()
        $winner = $null
        $lastOutput = $null
        try {
            foreach ($item in $script:WizardPs.EndInvoke($script:WizardAsync)) {
                $lastOutput = $item
                if ($item -and $item.PSObject.Properties['Id'] -and $item.PSObject.Properties['StartFailed']) { $winner = $item }
            }
        } catch {
            if (-not $script:WizardCancelled) {
                Add-WizardLog ('[x] ' + $_.Exception.Message)
                $script:WizardErrIndex++
            }
        }
        try { $script:WizardPs.Dispose() } catch { }
        try { $script:WizardRunspace.Dispose() } catch { }
        $script:WizardPs = $null
        $script:WizardBusy = $false
        Update-WizardChrome
        if ($script:WizardCancelled) {
            Complete-WizardCancelled
        } elseif ($script:WizardMode -eq 'voice') {
            Complete-VoiceCheck -Summary $lastOutput
        } elseif ($script:WizardMode -eq 'action') {
            Complete-ControlAction -Failed ($script:WizardErrIndex -gt 0)
        } else {
            Complete-WizardBenchmark -Winner $winner
        }
    } catch {
        try { $script:WizardTimer.Stop() } catch { }
        $script:WizardBusy = $false
        Update-WizardChrome
        if ($script:WizardCancelled) {
            Complete-WizardCancelled
        } else {
            Show-ControlError $_.Exception.Message
            if ($script:WizardMode -eq 'voice') {
                Complete-VoiceCheck -Summary $null
            } elseif ($script:WizardMode -eq 'action') {
                Complete-ControlAction -Failed $true
            } else {
                Set-WizardStep -Step 'type'
            }
        }
    }
}

function Complete-WizardBenchmark {
    # Mirrors the console master's fail-closed rules: install is offered only
    # for a repeat-verified, gate-approved candidate.
    param($Winner)
    $script:WizardWinner = $Winner
    $script:WizardAutoInstalled = $false
    $btnWizDoh = Get-Variable -Name BtnWizDoh -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($btnWizDoh) { $btnWizDoh.Visibility = 'Collapsed' }
    $btnWizRetry = Get-Variable -Name BtnWizRetry -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($btnWizRetry) { $btnWizRetry.Visibility = 'Collapsed' }
    $btnWizConflicts = Get-Variable -Name BtnWizConflicts -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($btnWizConflicts) {
        if ([bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $btnWizConflicts.Content = 'Включить отключённые обратно'
            $btnWizConflicts.Visibility = 'Visible'
        } else {
            $btnWizConflicts.Visibility = 'Collapsed'
        }
    }
    $conflictList = @()
    if ($Winner -and $Winner.PSObject.Properties['Conflicts']) { $conflictList = @($Winner.Conflicts) }
    if ($null -eq $Winner) {
        $script:TxtWizResultTitle.Text = 'Проверка не дала результата'
        $script:TxtWizResultBody.Text = 'Не удалось проверить стратегии. Проверьте подключение и запустите диагностику из раздела «Дополнительно».'
        $script:BtnWizInstall.Visibility = 'Collapsed'
        $script:BtnWizSkip.Content = 'Готово'
        if ($btnWizRetry) { $btnWizRetry.Visibility = 'Visible' }
        $logText = ''
        $logObj = Get-Variable -Name TxtWizLog -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($logObj) { $logText = [string]$logObj.Text }
        if ($logText -match 'Обнаружены конфликтующие программы|Conflicting software detected') {
            $script:TxtWizResultBody.Text = $script:TxtWizResultBody.Text + "`r`nКонфликтующие программы найдены — отключите их кнопкой ниже и повторите проверку."
            if ($btnWizConflicts) {
                $btnWizConflicts.Visibility = 'Visible'
                if (-not [bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
                    $btnWizConflicts.Content = 'Отключить конфликтующие и повторить'
                }
            }
        }
        Set-WizardStep -Step 'result'
        return
    }
    $winnerId = if ($Winner.PSObject.Properties['Id']) { [string]$Winner.Id } else { '' }
    $winnerName = if ($Winner.PSObject.Properties['Name'] -and $Winner.Name) { [string]$Winner.Name } else { $winnerId }
    $startFailed = [bool]($Winner.PSObject.Properties['StartFailed'] -and $Winner.StartFailed)
    $passedCount = if ($Winner.PSObject.Properties['Passed']) { [int]$Winner.Passed } else { 0 }
    $totalMsValue = if ($Winner.PSObject.Properties['TotalMs']) { [double]$Winner.TotalMs } else { 0 }
    $allServicesPassed = [bool]($Winner.PSObject.Properties['AllServicesPassed'] -and $Winner.AllServicesPassed)
    $freezeOk = [bool]($Winner.PSObject.Properties['FreezeOk'] -and $Winner.FreezeOk)
    $carrierMode = [bool]$script:WizardCarrier
    $confidenceAccepted = $false
    $reason = ''
    if ($Winner.PSObject.Properties['AutoSelectConfidence'] -and $Winner.AutoSelectConfidence) {
        $conf = $Winner.AutoSelectConfidence
        $canInstall = [bool]($conf.PSObject.Properties['CanInstall'] -and $conf.CanInstall)
        $stable = [bool]($conf.PSObject.Properties['Stable'] -and $conf.Stable)
        $decision = if ($conf.PSObject.Properties['Decision']) { [string]$conf.Decision } else { '' }
        $confidenceAccepted = [bool]($canInstall -or ($stable -and $decision -eq 'keep-current'))
        $reason = if ($conf.PSObject.Properties['Reason']) { [string]$conf.Reason } else { '' }
    }
    $candidateUsable = [bool](-not $startFailed -and $passedCount -gt 0 -and $confidenceAccepted)
    if ($carrierMode -and (-not $allServicesPassed -or -not $freezeOk)) { $candidateUsable = $false }

    $body = New-Object 'System.Collections.Generic.List[string]'
    $body.Add(('Лучший вариант: {0} ({1})' -f $winnerName, $winnerId))
    if (-not $startFailed) {
        $body.Add(('Доступно адресов: {0}; время проверки: {1:N0} мс' -f $passedCount, $totalMsValue))
    } else {
        $body.Add('winws.exe не запустился во время проверки.')
        if ($Winner.PSObject.Properties['StartError'] -and $Winner.StartError) {
            $body.Add(('Причина: {0}' -f $Winner.StartError))
        } else {
            $body.Add('Частые причины: антивирус удалил bin\winws.exe, конфликт WinDivert с другими обходами, нет прав администратора.')
        }
    }
    if ($Winner.PSObject.Properties['FreezeChecked'] -and $Winner.FreezeChecked) {
        $freezePassed = if ($Winner.PSObject.Properties['FreezePassed']) { [int]$Winner.FreezePassed } else { 0 }
        $freezeTotal = if ($Winner.PSObject.Properties['FreezeTotal']) { [int]$Winner.FreezeTotal } else { 0 }
        $body.Add(('Передача 64 КБ: {0}/{1}' -f $freezePassed, $freezeTotal))
    }
    if ($carrierMode) {
        $servicesPassed = if ($Winner.PSObject.Properties['ServicesPassed']) { [int]$Winner.ServicesPassed } else { 0 }
        $serviceCount = if ($Winner.PSObject.Properties['ServiceCount']) { [int]$Winner.ServiceCount } else { 0 }
        $body.Add(('Сервисы: {0}/{1}' -f $servicesPassed, $serviceCount))
    }
    if ($reason) {
        $reasonText = [string]$reason
        $reasonRu = @{
            'repeat verification matched' = 'повторная проверка совпала'
            'candidate did not start or reach any endpoint' = 'вариант не стартовал или не достиг ни одного адреса'
            'repeat verification failed or tested a different strategy' = 'повторная проверка не прошла или проверялась другая стратегия'
            'the successful endpoint set changed between runs' = 'набор успешных адресов изменился между прогонами'
            'the successful endpoint count changed between runs' = 'число успешных адресов изменилось между прогонами'
            'the 64 KB transfer check was not stable' = 'проверка передачи 64 КБ была нестабильна'
            'the successful 64 KB transfer endpoints changed between runs' = 'успешные серверы передачи 64 КБ изменились между прогонами'
        }
        if ($reasonRu.ContainsKey($reasonText)) { $reasonText = $reasonRu[$reasonText] }
        $body.Add(('Решение автоматики: {0}' -f $reasonText))
    }

    if ($candidateUsable) {
        $autoError = ''
        if (-not $winnerId) {
            $autoError = 'нет идентификатора стратегии'
        } else {
            try {
                Install-ZapretService -StrategyId $winnerId | Out-Null
                $script:WizardAutoInstalled = $true
            } catch {
                $autoError = $_.Exception.Message
            }
        }
        if ($script:WizardAutoInstalled) {
            $script:TxtWizResultTitle.Text = 'Лучший вариант выбран и запущен'
            $body.Add(('Стратегия {0} вставлена в автозапуск и запущена.' -f $winnerId))
            $script:BtnWizInstall.Visibility = 'Collapsed'
            $script:BtnWizSkip.Content = 'Продолжить'
            try { Refresh-ControlStatus } catch { }
        } else {
            $script:TxtWizResultTitle.Text = 'Вариант подтверждён повторной проверкой'
            $body.Add(('Автоустановка не удалась: {0}' -f $autoError))
            $body.Add('Установка выполняется кнопкой ниже.')
            $script:BtnWizInstall.Visibility = 'Visible'
            $script:BtnWizSkip.Content = 'Не устанавливать'
        }
    } else {
        $script:TxtWizResultTitle.Text = 'Убедительного результата нет'
        $body.Add('Ничего не изменено: служба, hosts/IPSet и DNS не тронуты. Можно попробовать другой тип подключения или повторить позже.')
        if ($carrierMode -and -not $allServicesPassed) {
            $body.Add('Профиль оператора перебирает только 4 узкие стратегии. Запустите мастер заново и выберите обычную проверку стратегий — она перебирает полный набор.')
        }
        if ($btnWizRetry) { $btnWizRetry.Visibility = 'Visible' }
        $targetReasonTokens = @()
        if (-not $startFailed -and $Winner.PSObject.Properties['Targets']) {
            foreach ($t in @($Winner.Targets)) {
                if ($t -and $t.PSObject.Properties['Reason'] -and $t.Reason) { $targetReasonTokens += [string]$t.Reason }
            }
        }
        $dnsFailures = @($targetReasonTokens | Where-Object { $_ -eq 'dns' }).Count
        $timeoutFailures = @($targetReasonTokens | Where-Object { $_ -eq 'timeout' }).Count
        $resetFailures = @($targetReasonTokens | Where-Object { $_ -in 'reset','refused','empty' }).Count
        $winnerDnsSuspect = [bool]($Winner.PSObject.Properties['DnsSuspect'] -and $Winner.DnsSuspect)
        if (($dnsFailures -gt 0 -and $dnsFailures -ge [Math]::Max($timeoutFailures, $resetFailures)) -or $winnerDnsSuspect) {
            $body.Add('Похоже, DNS не резолвит проверочные адреса — стратегии тут ни при чём. Включите DoH кнопкой ниже и повторите проверку.')
            if ($btnWizDoh) { $btnWizDoh.Visibility = 'Visible' }
        } elseif ($timeoutFailures -gt 0 -and $timeoutFailures -ge $resetFailures) {
            $freezePassedHint = 0
            if ($Winner.PSObject.Properties['FreezeChecked'] -and $Winner.FreezeChecked -and $Winner.PSObject.Properties['FreezePassed']) { $freezePassedHint = [int]$Winner.FreezePassed }
            if ($freezePassedHint -gt 0) {
                $body.Add('Канал живой: передача 64 КБ от тестовых серверов прошла, а домены Discord/YouTube/WhatsApp не отвечают — похоже, DPI блокирует их по SNI. Попробуйте другие fakes (раздел «Ещё») или обычную проверку стратегий без профиля оператора.')
            } else {
                $body.Add('Адреса не ответили за отведённое время — похоже, канал медленный или частично недоступен. Повторите проверку при лучшей связи.')
            }
            $proxyNames = @()
            foreach ($proxyName in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy')) {
                $proxyValue = [Environment]::GetEnvironmentVariable($proxyName)
                if ($proxyValue) { $proxyNames += $proxyName }
            }
            if ($proxyNames.Count -gt 0) {
                $body.Add(('Обнаружены прокси-переменные окружения ({0}). Наши пробы идут напрямую, а другие утилиты могут учитывать прокси и показывать ложный успех — поэтому их «работает», а приложения нет.' -f ($proxyNames -join ', ')))
            }
        } elseif ($resetFailures -gt 0) {
            $body.Add('Соединения сбрасывались — похоже, DPI блокирует эти адреса. Попробуйте другие fakes (раздел «Ещё») или обычный подбор из консоли.')
        }
        $script:BtnWizInstall.Visibility = 'Collapsed'
        $script:BtnWizSkip.Content = 'Готово'
    }
    if ($conflictList.Count -gt 0) {
        $body.Add(('Конфликтующие программы: {0}. Их можно отключить кнопкой ниже — это обратимо.' -f ($conflictList -join ', ')))
        if ($btnWizConflicts) {
            $btnWizConflicts.Visibility = 'Visible'
            if (-not [bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
                $btnWizConflicts.Content = 'Отключить конфликтующие и повторить'
            }
        }
    }
    $script:TxtWizResultBody.Text = ($body -join "`r`n")
    Set-WizardStep -Step 'result'
}

function Complete-VoiceRepairResult {
    # Displays the Repair-DiscordVoice summary (repair shape: Repaired/Actions/
    # CurrentFake/NextFakeTried) in the wizard result step.
    param($Summary)
    $body = New-Object 'System.Collections.Generic.List[string]'
    $actions = @()
    if ($Summary.PSObject.Properties['Actions'] -and $Summary.Actions) { $actions = @($Summary.Actions) }
    $currentFake = ''
    if ($Summary.PSObject.Properties['CurrentFake']) { $currentFake = [string]$Summary.CurrentFake }
    $conflictItems = @()
    if ($Summary.PSObject.Properties['Conflicts'] -and $null -ne $Summary.Conflicts) { $conflictItems = @($Summary.Conflicts) }
    $switchedOnly = [bool]($Summary.Repaired -and $Summary.PSObject.Properties['NextFakeTried'] -and $Summary.NextFakeTried)
    if ($switchedOnly) {
        $script:TxtWizResultTitle.Text = 'Фейк голоса заменён'
        $body.Add(('Активный UDP-фейк: {0}.' -f $currentFake))
        $body.Add('Переподключитесь к голосовому каналу и проверьте пинг. Если пинг снова ~5000 мс — нажмите «Сменить фейк голоса» ещё раз.')
    } elseif ([bool]$Summary.Repaired) {
        $script:TxtWizResultTitle.Text = 'Голосовой путь починен'
        foreach ($a in $actions) { $body.Add(('• {0}' -f $a)) }
        $body.Add('Переподключитесь к голосовому каналу и проверьте пинг/подключение.')
        $body.Add('Если пинг снова ~5000 мс — кнопка «Сменить фейк голоса» переберёт следующий фейк.')
    } elseif ([bool]$Summary.VoiceLikely) {
        $script:TxtWizResultTitle.Text = 'Голосовой путь выглядит рабочим'
        $body.Add('Проверка ничего не меняла: путь жив.')
        $body.Add('Если в Discord пинг ~5000 мс или войс не подключается — нажмите «Сменить фейк голоса» (сменит фейк и перезапустит обход; повторяйте, пока голос не станет нормальным).')
    } else {
        $script:TxtWizResultTitle.Text = 'Автопочинка не помогла'
        foreach ($a in $actions) { $body.Add(('• {0}' -f $a)) }
        if ($conflictItems.Count -gt 0) { $body.Add(('Возможные конфликты: {0}' -f ($conflictItems -join '; '))) }
        $body.Add('Обычные причины: конфликтующие VPN/обходы, фаервол/антивирус, провайдер режет UDP. Уберите конфликт и повторите проверку.')
    }
    $script:TxtWizResultBody.Text = ($body -join "`r`n")
    $script:BtnWizInstall.Visibility = 'Collapsed'
    $script:BtnWizSkip.Content = 'Готово'
    Set-WizardStep -Step 'result'
}

function Complete-VoiceCheck {
    # Shows the voice check summary in the wizard result step. Pure display
    # logic: the probes themselves run in Test-DiscordVoiceConnection.
    param($Summary)
    if ($Summary -and $Summary.PSObject.Properties['Repaired']) {
        Complete-VoiceRepairResult -Summary $Summary
        return
    }
    $extraDoh = Get-Variable -Name BtnWizDoh -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $extraRetry = Get-Variable -Name BtnWizRetry -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraDoh) { $extraDoh.Visibility = 'Collapsed' }
    if ($extraRetry) { $extraRetry.Visibility = 'Collapsed' }
    $extraConf = Get-Variable -Name BtnWizConflicts -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($extraConf) {
        if ([bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $extraConf.Content = 'Включить отключённые обратно'
            $extraConf.Visibility = 'Visible'
        } else {
            $extraConf.Visibility = 'Collapsed'
        }
    }
    if ($null -eq $Summary -or -not $Summary.PSObject.Properties['VoiceLikely']) {
        $script:TxtWizResultTitle.Text = 'Проверка не завершилась'
        $script:TxtWizResultBody.Text = 'Не удалось выполнить проверку голоса. Проверьте подключение и повторите.'
        $script:BtnWizInstall.Visibility = 'Collapsed'
        $script:BtnWizSkip.Content = 'Готово'
        Set-WizardStep -Step 'result'
        return
    }
    $tcpOk = [bool]($Summary.PSObject.Properties['TcpSignallingOk'] -and $Summary.TcpSignallingOk)
    $fakeTried = [bool]($Summary.PSObject.Properties['FakeTried'] -and $Summary.FakeTried)
    $udpFakeOk = [bool]($Summary.PSObject.Properties['UdpFakeOk'] -and $Summary.UdpFakeOk)
    $udpStunOk = [bool]($Summary.PSObject.Properties['UdpStunOk'] -and $Summary.UdpStunOk)
    $udpBaselineOk = [bool]($Summary.PSObject.Properties['UdpBaselineOk'] -and $Summary.UdpBaselineOk)
    $body = New-Object 'System.Collections.Generic.List[string]'
    $body.Add(('Сигнальный канал TCP (discord.media): {0}' -f $(if ($tcpOk) { 'OK' } else { 'не проходит' })))
    if (-not $fakeTried) {
        $body.Add('Активный UDP-фейк не найден (bin\ACTIVE_DISCORD_UDP.bin) - выберите фейк в классическом меню, пункт 7.')
    } else {
        $body.Add(('UDP с активным фейком: {0}' -f $(if ($udpFakeOk) { 'ответ получен' } else { 'ответа нет' })))
    }
    $body.Add(('UDP до Discord (STUN): {0}' -f $(if ($udpStunOk) { 'OK' } else { 'ответа нет' })))
    $body.Add(('UDP в целом (базовая проверка): {0}' -f $(if ($udpBaselineOk) { 'OK' } else { 'ответа нет' })))
    $conflictItems = @()
    if ($Summary.PSObject.Properties['Conflicts'] -and $null -ne $Summary.Conflicts) { $conflictItems = @($Summary.Conflicts) }
    if ($conflictItems.Count -gt 0) {
        $body.Add(('Возможные конфликты: {0}' -f ($conflictItems -join '; ')))
    } else {
        $body.Add('Конфликты с другими обходами/VPN не найдены.')
    }
    $dnsFailed = [bool]($Summary.PSObject.Properties['DnsFailed'] -and $Summary.DnsFailed)
    $verdict = Get-VoiceCheckVerdict -TcpOk $tcpOk -UdpFakeOk $udpFakeOk -UdpStunOk $udpStunOk -UdpBaselineOk $udpBaselineOk -DnsFailed $dnsFailed
    if ($verdict.Code -eq 'ok') {
        $script:TxtWizResultTitle.Text = 'Голосовой путь выглядит рабочим'
        $body.Add('Если войс всё равно не подключается, смените фейк (классическое меню, пункт 7) и проверьте фаервол/антивирус.')
    } elseif ($verdict.Code -eq 'dns') {
        $script:TxtWizResultTitle.Text = 'DNS не разрешил discord.media'
        $body.Add('Проверьте подключение и DNS-настройки (zapret.ps1 dns status), затем повторите проверку.')
    } elseif ($verdict.Code -eq 'udp-wide') {
        $script:TxtWizResultTitle.Text = 'UDP не проходит вообще'
        $body.Add('Чаще всего мешает конфликтующая программа (список выше), фаервол или провайдер. Уберите конфликт и повторите проверку.')
    } elseif ($verdict.Code -eq 'tcp') {
        $script:TxtWizResultTitle.Text = 'Сигнальный канал не проходит'
        $body.Add('Проблема с TCP-трафиком/обходом: голос не установится, пока не заработает TCP до discord.media.')
    } else {
        $script:TxtWizResultTitle.Text = 'UDP до Discord не проходит'
        $body.Add('Попробуйте другой фейк для Discord (классическое меню, пункт 7), затем перезапустите службу и повторите проверку.')
    }
    $script:TxtWizResultBody.Text = ($body -join "`r`n")
    $script:BtnWizInstall.Visibility = 'Collapsed'
    $script:BtnWizSkip.Content = 'Готово'
    Set-WizardStep -Step 'result'
}

function Get-ControlShortcutState {
    $marker = Join-Path (Join-Path $script:AppRoot 'utils') 'control-shortcut.asked'
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = [Environment]::GetFolderPath('UserProfile') }
    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = '.' }
    $lnkPath = Join-Path $desktop 'OpenZapret.lnk'
    return [pscustomobject]@{
        Asked          = (Test-Path -LiteralPath $marker -PathType Leaf)
        MarkerPath     = $marker
        ShortcutPath   = $lnkPath
        ShortcutExists = (Test-Path -LiteralPath $lnkPath -PathType Leaf)
    }
}

function Install-ControlShortcut {
    # Creates the desktop shortcut that starts the panel like a normal app:
    # system PowerShell, hidden console window, custom icon.
    [CmdletBinding()]
    param()
    $iconPath = Join-Path $script:AppRoot 'Zapret-Control.ico'
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Не найден Zapret-Control.ico рядом с приложением.' }
    $psExe = Get-WindowsSystemToolPath -Name 'powershell.exe'
    if (-not $psExe) { throw 'Не найден Windows PowerShell.' }
    $state = Get-ControlShortcutState
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($state.ShortcutPath)
    $launcherExePath = Join-Path $script:AppRoot 'Zapret-Control.exe'
    if (Test-Path $launcherExePath) {
        # Native launcher: double-clickable "Application" with the embedded icon
        $shortcut.TargetPath = $launcherExePath
        $shortcut.Arguments = ''
    } else {
        $shortcut.TargetPath = $psExe
        $shortcut.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:AppRoot 'Zapret-Control.ps1')
    }
    $shortcut.WorkingDirectory = $script:AppRoot
    $shortcut.IconLocation = '{0},0' -f $iconPath
    $shortcut.Description = 'OpenZapret — панель управления обходом'
    $shortcut.Save()
    return $state.ShortcutPath
}

function Set-ControlShortcutAsked {
    $state = Get-ControlShortcutState
    $markerDir = Split-Path -Parent $state.MarkerPath
    if (-not (Test-Path -LiteralPath $markerDir -PathType Container)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $state.MarkerPath -PathType Leaf)) { New-Item -ItemType File -Path $state.MarkerPath -Force | Out-Null }
}

function Update-SiteRecommendationPreview {
    $selected = $script:ComboRecommendation.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.Recommendation) {
        $script:TxtSiteDomains.Text = ''
        $script:TxtSiteNote.Text = ''
        return
    }
    $record = $selected.Recommendation
    $script:TxtSiteDomains.Text = @($record.Domains) -join "`r`n"
    $script:TxtSiteNote.Text = [string]$record.NoteRu
}

function Get-ExcludedRecommendationDomains {
    param([Parameter(Mandatory = $true)]$Recommendation)
    $listsDirectory = Get-ZapretListsDir
    $excluded = @{}
    foreach ($excludeFile in @((Join-Path $listsDirectory 'list-exclude.txt'), (Join-Path $listsDirectory 'list-exclude-user.txt'))) {
        if (-not (Test-Path -LiteralPath $excludeFile -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $excludeFile -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace([string]$line) -or $line.Trim() -match '^#') { continue }
            $domain = ConvertTo-Domain -InputText ([string]$line)
            if ($domain) { $excluded[$domain] = $true }
        }
    }
    $blocked = @()
    foreach ($siteDomain in $Recommendation.Domains) {
        foreach ($excludedDomain in $excluded.Keys) {
            if ($siteDomain.Equals([string]$excludedDomain, [StringComparison]::OrdinalIgnoreCase) -or $siteDomain.EndsWith(('.' + [string]$excludedDomain), [StringComparison]::OrdinalIgnoreCase)) {
                $blocked += $siteDomain
                break
            }
        }
    }
    return @($blocked | Select-Object -Unique)
}

function Add-ControlSiteRecommendation {
    $selected = $script:ComboRecommendation.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.Recommendation) { return }
    $recommendation = $selected.Recommendation
    $blocked = @(Get-ExcludedRecommendationDomains -Recommendation $recommendation)
    if ($blocked.Count -gt 0) {
        $blockedText = (($blocked | Select-Object -Unique) -join ', ')
        $message = "Эти домены уже находятся в списке исключений: $blockedText.`r`nДобавление их в список обхода не отменит исключение, поэтому рекомендация не применена."
        [void][System.Windows.MessageBox]::Show($script:Window, $message, 'Есть исключение', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        Add-ControlActivity -Message ("Рекомендация {0} не добавлена: домены исключены." -f $recommendation.NameRu)
        return
    }

    $domainPreview = (@($recommendation.Domains) -join "`r`n")
    $confirmation = "Добавить домены для $($recommendation.NameRu) в личный список обхода?`r`n`r`n$domainPreview`r`n`r`nСписок не гарантирует работу сайта или приложения."
    $answer = [System.Windows.MessageBox]::Show($script:Window, $confirmation, 'Подтверждение', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        Add-ControlActivity -Message 'Добавление отменено; списки не изменены.'
        return
    }

    $added = 0
    $existing = 0
    try {
        foreach ($domain in $recommendation.Domains) {
            $result = Add-DomainToList -Domain $domain -Kind general
            if ($result -eq 'added') { $added++ } else { $existing++ }
        }
    } catch {
        Show-ControlError $_.Exception.Message
        if ($added -gt 0) { Add-ControlActivity -Message 'Часть доменов добавлена; проверьте личный список.' }
        return
    }
    Add-ControlActivity -Message ("{0}: добавлено {1}, уже было {2}." -f $recommendation.NameRu, $added, $existing)

    if ($added -gt 0 -and $script:CurrentServiceInfo -and $script:CurrentServiceInfo.Installed -and [string]$script:CurrentServiceInfo.State -eq 'Running') {
        $restartAnswer = [System.Windows.MessageBox]::Show($script:Window, 'Список изменён. Перезапустить службу сейчас, чтобы применить изменения?', 'Перезапуск zapret', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($restartAnswer -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                Restart-Service -Name 'zapret' -Force -ErrorAction Stop
                (Get-Service -Name 'zapret').WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
                Add-ControlActivity -Message 'Служба перезапущена.'
            } catch { Show-ControlError $_.Exception.Message }
        } else {
            Add-ControlActivity -Message 'Перезапуск пропущен; изменения вступят в силу после следующего запуска службы.'
        }
    }
    Refresh-ControlStatus
}

$profileItems = @(Get-BypassProfiles | ForEach-Object { [pscustomobject]@{ Label = [string]$_.NameRu; Profile = $_ } })
$script:CmbProfile.ItemsSource = $profileItems
$script:CmbProfile.DisplayMemberPath = 'Label'
try {
    $currentProfileId = Get-BypassProfile
    for ($pi = 0; $pi -lt $profileItems.Count; $pi++) {
        if ($profileItems[$pi].Profile.Id -eq $currentProfileId) { $script:CmbProfile.SelectedIndex = $pi }
    }
} catch { }
Update-ProfileCard

$recommendations = @(Get-RecommendedSiteCatalog)
$recommendationItems = @($recommendations | ForEach-Object { [pscustomobject]@{ Label = [string]$_.NameRu; Recommendation = $_ } })
$script:ComboRecommendation.ItemsSource = $recommendationItems
$script:ComboRecommendation.DisplayMemberPath = 'Label'
if ($recommendationItems.Count -gt 0) { $script:ComboRecommendation.SelectedIndex = 0 }
Update-SiteRecommendationPreview

$window.FindName('navHome').Add_Click({ Set-ControlPage -Page home })
$window.FindName('navStrategies').Add_Click({ Set-ControlPage -Page strategies })
$window.FindName('navNetwork').Add_Click({ Set-ControlPage -Page network })
$window.FindName('navSites').Add_Click({ Set-ControlPage -Page sites })
$window.FindName('navMore').Add_Click({ Set-ControlPage -Page more })
$window.FindName('btnBackToWizard').Add_Click({ if ($script:WizardBusy) { Set-ControlPage -Page 'wizard' } })
$window.FindName('btnWizCancel').Add_Click({ Stop-WizardRun })
$window.FindName('btnRefresh').Add_Click({ Refresh-ControlStatus })
$window.FindName('btnHelp').Add_Click({ try { Show-ControlHelp } catch { Show-ControlError $_.Exception.Message } })
$window.FindName('btnStartService').Add_Click({
    try {
        $info = Get-ZapretServiceInfo
        if (-not $info.Installed) { throw 'Служба zapret не установлена. Запустите автонастройку.' }
        if ([string]$info.State -eq 'Running') { Add-ControlActivity -Message 'Служба уже работает.'; return }
        try {
            Start-Service -Name 'zapret' -ErrorAction Stop
            (Get-Service -Name 'zapret').WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
            Add-ControlActivity -Message 'Служба запущена.'
        } catch {
            $startErr = $_.Exception.Message
            Add-ControlActivity -Message ('Быстрый запуск не удался: {0} — пробую переустановить текущую стратегию…' -f $startErr)
            $strategyId = [string]$info.Strategy
            if ([string]::IsNullOrWhiteSpace($strategyId)) {
                try { $strategyId = [string](Get-Config).lastStrategy } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($strategyId)) { throw ('Не удалось запустить службу: {0}' -f $startErr) }
            Install-ZapretService -StrategyId $strategyId | Out-Null
            Add-ControlActivity -Message ('Служба переустановлена стратегией {0} и запущена.' -f $strategyId)
        }
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message; Refresh-ControlStatus }
})
$window.FindName('btnStopService').Add_Click({
    $answer = [System.Windows.MessageBox]::Show($window, 'Остановить обход? Служба и winws.exe этой установки будут выключены, драйвер WinDivert этой установки будет выгружен. Чтобы снова включить, нажмите «Запустить службу» или установите стратегию.', 'Остановить zapret', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        $report = Stop-ZapretServiceRobust
        if ($report.ServiceStopped) { Add-ControlActivity -Message 'Служба остановлена.' }
        if ($report.OwnProcessesStopped -gt 0) { Add-ControlActivity -Message ('Остановлено процессов winws.exe: {0}.' -f $report.OwnProcessesStopped) }
        if ($report.ForeignProcesses.Count -gt 0) { Add-ControlActivity -Message ('Чужие winws.exe других установок не тронуты (PID: {0}).' -f (($report.ForeignProcesses | ForEach-Object { $_.Id }) -join ', ')) }
        if ($report.DriversStopped) { Add-ControlActivity -Message 'Драйвер WinDivert этой установки выгружен.' }
        elseif ($report.DriverNote) { Add-ControlActivity -Message ('Драйвер WinDivert: {0}' -f $report.DriverNote) }
        Add-ControlActivity -Message 'Обход остановлен.'
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message; Refresh-ControlStatus }
})
$window.FindName('btnAutoSetup').Add_Click({
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Мастер уже выполняет проверку — дождитесь результата.'; return }
    Set-WizardStep -Step 'type'
    Set-ControlPage -Page 'wizard'
})
$window.FindName('btnCheckBypass').Add_Click({
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Другое действие ещё выполняется — дождитесь завершения.'; return }
    Start-ControlAction -Title 'Проверка обхода' -Action {
        $probe = Invoke-BypassHealthProbe
        foreach ($row in $probe.Rows) {
            $status = if ($row.Ok) { ('OK {0} мс' -f $row.Ms) } else { ('нет ответа ({0})' -f $row.Reason) }
            Write-Host ('    {0,-22} {1}' -f $row.Name, $status) -ForegroundColor $(if ($row.Ok) { 'Green' } else { 'Red' })
        }
        if ($probe.Passed -ge ($probe.Total - 1)) {
            Write-Host (Get-UiText -Russian ("Обход работает: {0} из {1}." -f $probe.Passed, $probe.Total) -English ("The bypass works on {0} of {1} endpoints." -f $probe.Passed, $probe.Total)) -ForegroundColor Green
        } else {
            Write-Host (Get-UiText -Russian ("Обход НЕ работает: отвечает {0} из {1}. Запустите автонастройку." -f $probe.Passed, $probe.Total) -English ("The bypass does NOT work: {0} of {1} answer. Run automatic setup." -f $probe.Passed, $probe.Total)) -ForegroundColor Red
        }
    }
})
$window.FindName('btnSpeedTest').Add_Click({
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Другое действие ещё выполняется — дождитесь завершения.'; return }
    Start-ControlAction -Title 'Тест скорости' -Action {
        $speed = Invoke-SpeedTest
        foreach ($row in $speed.Rows) {
            $line = if ($row.Ok) { ('{0:N1} КБ/с' -f $row.SpeedKBs) } else { 'нет данных' }
            Write-Host ('    {0,-18} {1}' -f $row.Name, $line) -ForegroundColor $(if ($row.Ok) { 'Green' } else { 'Red' })
        }
        $verdict = switch ($speed.Verdict) {
            'excellent' { 'Скорость отличная.' }
            'ok'        { 'Скорость нормальная.' }
            'slow'      { 'Скорость низкая — обход или канал замедляет трафик.' }
            default     { 'Скачать данные не удалось.' }
        }
        Write-Host ('    Итог: {0:N1} КБ/с. {1}' -f $speed.BestKBs, $verdict) -ForegroundColor Cyan
    }
})
$window.FindName('btnProfileApply').Add_Click({
    try {
        $selected = $script:CmbProfile.SelectedItem
        if ($null -eq $selected -or $null -eq $selected.Profile) { throw 'Выберите профиль.' }
        $answer = [System.Windows.MessageBox]::Show($script:Window, ("Применить профиль «{0}»? Ваши собственные записи в списке исключений сохраняются." -f $selected.Label), 'Профиль обхода', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $result = Set-BypassProfile -Profile ([string]$selected.Profile.Id)
        Add-ControlActivity -Message ("Профиль «{0}» применён: исключено доменов: {1}." -f $selected.Label, $result.Domains.Count)
        if ($script:CurrentServiceInfo -and $script:CurrentServiceInfo.Installed -and [string]$script:CurrentServiceInfo.State -eq 'Running') {
            $restartAnswer = [System.Windows.MessageBox]::Show($script:Window, 'Список изменён. Перезапустить службу сейчас, чтобы применить изменения?', 'Перезапуск zapret', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($restartAnswer -eq [System.Windows.MessageBoxResult]::Yes) {
                try {
                    Restart-Service -Name 'zapret' -Force -ErrorAction Stop
                    (Get-Service -Name 'zapret').WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
                    Add-ControlActivity -Message 'Служба перезапущена.'
                } catch { Show-ControlError $_.Exception.Message }
            } else {
                Add-ControlActivity -Message 'Перезапуск пропущен; изменения вступят в силу после следующего запуска службы.'
            }
        }
        Update-ProfileCard
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnSiteCheck').Add_Click({
    $siteText = ''
    if ($script:TxtSiteCheckInput) { $siteText = [string]$script:TxtSiteCheckInput.Text }
    if ([string]::IsNullOrWhiteSpace($siteText)) { Show-ControlError 'Введите адрес сайта.'; return }
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Другое действие ещё выполняется — дождитесь завершения.'; return }
    Start-ControlAction -Title 'Проверка сайта' -Action {
        $check = Invoke-SiteCheck -InputText $siteText
        Write-Host ('    ' + $check.NoteRu) -ForegroundColor Gray
        $probeLine = if ($check.ProbeOk) { ('отвечает, {0} мс' -f $check.ProbeMs) } else { 'не отвечает' }
        $transferLine = switch ($check.TransferState) {
            'full'   { (', передача {0:N1} КБ/с' -f $check.TransferKBs) }
            'small'  { ', страница меньше 64 КБ' }
            'freeze' { ', передача зависает' }
            default  { '' }
        }
        Write-Host ('    ' + $probeLine + $transferLine) -ForegroundColor $(if ($check.ProbeOk) { 'Green' } else { 'Red' })
        Write-Host ('    Итог: ' + $check.VerdictRu) -ForegroundColor Cyan
    }
})
$window.FindName('btnTrayAutostart').Add_Click({
    try {
        $state = Get-TrayAutostartState
        $mode = if ($state.Enabled) { 'disable' } else { 'enable' }
        [void](Set-TrayAutostart -Mode $mode)
        Add-ControlActivity -Message $(if ($mode -eq 'enable') { 'Автозапуск трея включён.' } else { 'Автозапуск трея выключен.' })
        Update-TrayAutostartCard
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnTray').Add_Click({
    try {
        $tray = Join-Path $script:AppRoot 'Zapret-Tray.exe'
        if (-not (Test-Path -LiteralPath $tray -PathType Leaf)) { throw 'Не найден Zapret-Tray.exe.' }
        Start-Process -FilePath $tray -WorkingDirectory $script:AppRoot | Out-Null
        Add-ControlActivity -Message 'Трей запущен: значок у часов, быстрые действия по правой кнопке.'
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnWatchdogToggle').Add_Click({
    try {
        if (Test-WatchdogSchedule) {
            Set-WatchdogSchedule -Disable
            Add-ControlActivity -Message 'Автозащита выключена.'
        } else {
            Set-WatchdogSchedule -Enable
            Add-ControlActivity -Message 'Автозащита включена: проверка обхода каждые 4 часа.'
        }
        Update-WatchdogCard
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('cmbRecommendation').Add_SelectionChanged({ Update-SiteRecommendationPreview })
$window.FindName('btnAddRecommendation').Add_Click({ Add-ControlSiteRecommendation })
$window.FindName('btnClassicMenu').Add_Click({
    try {
        $batch = Join-Path $script:AppRoot 'zapret.bat'
        if (-not (Test-Path -LiteralPath $batch -PathType Leaf)) { throw 'Не найден zapret.bat.' }
        Start-Process -FilePath $batch -WorkingDirectory $script:AppRoot | Out-Null
        Add-ControlActivity -Message 'Открыто классическое меню zapret.bat.'
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnWizRegular').Add_Click({
    Start-WizardBenchmark -Carrier '' -Fast ([bool]$script:ChkWizFast.IsChecked)
})
$window.FindName('btnWizMobile').Add_Click({ Set-WizardStep -Step 'carrier' })
$window.FindName('btnWizTypeCancel').Add_Click({ Set-ControlPage -Page 'home' })
$window.FindName('btnWizCarrierBack').Add_Click({ Set-WizardStep -Step 'type' })
$window.FindName('btnWizMts').Add_Click({ Start-WizardBenchmark -Carrier 'mts' -Fast $true })
$window.FindName('btnWizMegafon').Add_Click({ Start-WizardBenchmark -Carrier 'megafon' -Fast $true })
$window.FindName('btnWizTele2').Add_Click({ Start-WizardBenchmark -Carrier 'tele2' -Fast $true })
$window.FindName('btnWizYota').Add_Click({ Start-WizardBenchmark -Carrier 'yota' -Fast $true })
$window.FindName('btnWizInstall').Add_Click({
    try {
        if ($script:WizardWinner) {
            Install-ZapretService -StrategyId $script:WizardWinner.Id | Out-Null
            $script:WizardAutoInstalled = $true
            Add-ControlActivity -Message ('Служба установлена: {0}' -f $script:WizardWinner.Id)
            Set-WizardStep -Step 'hosts'
        }
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnWizDoh').Add_Click({
    if (-not (Confirm-ControlAction 'Включить DoH (Cloudflare) и повторить проверку стратегий? Изменение обратимо: «Вернуть DNS (DHCP)» или «Восстановить DNS из копии».')) { return }
    $script:WizardDohRerun = $true
    Start-ControlAction -Title 'DoH: cloudflare' -Action {
        param($ProviderName)
        Enable-Doh -Provider $ProviderName | Out-Null
        Write-Host 'DoH (Cloudflare) включён — повторяю проверку стратегий…'
    } -ArgumentList @('cloudflare')
})
$window.FindName('btnWizRetry').Add_Click({
    Start-WizardBenchmark -Carrier $script:WizardCarrier -Fast $script:WizardFast
})
$window.FindName('btnWizConflicts').Add_Click({
    $conflictsDisabled = [bool](Get-Variable -Name ConflictsDisabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($conflictsDisabled) {
        if (-not (Confirm-ControlAction 'Включить отключённые программы обратно? Прежние настройки запуска служб будут восстановлены.')) { return }
        $script:WizardConflictsMode = 'restore'
        Start-ControlAction -Title 'Конфликты: включение' -Action {
            $result = Restore-ZapretConflictPrograms
            if (-not $result.Found) { Write-Host 'Сохранённая копия настроек не найдена — включать нечего.' }
            foreach ($name in @($result.Restored)) { Write-Host ('Включено: {0}' -f $name) }
            foreach ($err in @($result.Failed)) { Write-Host ('Не выполнено: {0}' -f $err) -ForegroundColor Yellow }
        }
        return
    }
    if (-not (Confirm-ControlAction 'Отключить конфликтующие программы? Службы будут остановлены и отключены (это обратимо), конфликтующие процессы будут завершены. После отключения проверка стратегий повторится автоматически.')) { return }
    $script:WizardConflictsMode = 'disable'
    Start-ControlAction -Title 'Конфликты: отключение' -Action {
        $report = Get-ZapretConflictReport
        $result = Disable-ZapretConflictPrograms -Report $report
        foreach ($svc in @($result.Services)) { Write-Host ('Служба отключена: {0}' -f $svc.Name) }
        foreach ($procName in @($result.Processes)) { Write-Host ('Процесс завершён: {0}' -f $procName) }
        foreach ($err in @($result.Failed)) { Write-Host ('Не выполнено: {0}' -f $err) -ForegroundColor Yellow }
        if ($result.BackupPath) { Write-Host ('Прежние настройки служб сохранены: {0}' -f $result.BackupPath) -ForegroundColor DarkGray }
    }
})
$window.FindName('btnWizSkip').Add_Click({
    if ($script:WizardMode -eq 'action' -or $script:WizardMode -eq 'voice') {
        Set-ControlPage -Page 'home'
        Refresh-ControlStatus
        return
    }
    if ($script:WizardAutoInstalled) {
        Set-WizardStep -Step 'hosts'
        return
    }
    $script:TxtWizDoneBody.Text = 'Проверенный вариант не установлен; ничего не изменено. Мастер можно запустить снова в любой момент.'
    Set-WizardStep -Step 'done'
})
$window.FindName('btnWizHostsYes').Add_Click({
    try { Invoke-PostInstallConfiguration | Out-Null; Add-ControlActivity -Message 'hosts и IPSet обновлены.' } catch { Show-ControlError $_.Exception.Message }
    Set-WizardStep -Step 'sched'
})
$window.FindName('btnWizHostsNo').Add_Click({ Set-WizardStep -Step 'sched' })
$window.FindName('btnWizSchedYes').Add_Click({
    try { Set-AutoSelectSchedule -Enable | Out-Null; Add-ControlActivity -Message 'Еженедельная перепроверка включена.' } catch { Show-ControlError $_.Exception.Message }
    Complete-WizardDone
    Set-WizardStep -Step 'done'
})
$window.FindName('btnWizSchedNo').Add_Click({ Complete-WizardDone; Set-WizardStep -Step 'done' })
$window.FindName('btnWizFinish').Add_Click({
    Set-ControlPage -Page 'home'
    Refresh-ControlStatus
})
$window.FindName('btnCreateShortcut').Add_Click({
    try {
        $link = Install-ControlShortcut
        Add-ControlActivity -Message ('Ярлык создан: {0}' -f $link)
        Set-ControlShortcutAsked
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnDoctor').Add_Click({
    Start-ControlAction -Title 'Проверка установки' -Action {
        $doctorReport = Invoke-ZapretDoctor -Deep
        Write-Host ('Вердикт: {0}' -f $doctorReport.VerdictRu) -ForegroundColor $(if ($doctorReport.ExitCode -eq 0) { 'Green' } elseif ($doctorReport.ExitCode -eq 1) { 'Yellow' } else { 'Red' })
    }
})
$window.FindName('btnDoctorFix').Add_Click({
    Start-ControlAction -Title 'Проверка + ремонт' -Action {
        $doctorReport = Invoke-ZapretDoctor -Fix -Deep
        Write-Host ('Вердикт: {0}' -f $doctorReport.VerdictRu) -ForegroundColor $(if ($doctorReport.ExitCode -eq 0) { 'Green' } elseif ($doctorReport.ExitCode -eq 1) { 'Yellow' } else { 'Red' })
    }
})
$window.FindName('btnDiagnostics').Add_Click({
    Start-ControlAction -Title 'Диагностика' -Action { Invoke-Diagnostics -NoInteractive | Out-Null }
})
$window.FindName('btnVoiceCheck').Add_Click({
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Проверка уже выполняется — дождитесь результата.'; return }
    Start-WizardVoiceCheck
})
$window.FindName('btnVoiceNextFake').Add_Click({
    if ($script:WizardBusy) { Add-ControlActivity -Message 'Дождитесь завершения текущей проверки.'; return }
    Start-ControlAction -Title 'Смена фейка голоса' -Action {
        $fakeResult = Repair-DiscordVoice -NextFakeOnly
        Write-Host ('Активный фейк голоса: {0}' -f $fakeResult.CurrentFake) -ForegroundColor $(if ($fakeResult.Repaired) { 'Green' } else { 'Yellow' })
        Write-Host 'Переподключитесь к голосовому каналу и проверьте пинг. Если снова ~5000 мс — нажмите кнопку ещё раз.'
    }
})
$window.FindName('btnOpenLogs').Add_Click({
    try {
        $logs = Join-Path $script:AppRoot 'logs'
        if (-not (Test-Path -LiteralPath $logs -PathType Container)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $logs) | Out-Null
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnOpenFolder').Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:AppRoot) | Out-Null } catch { Show-ControlError $_.Exception.Message }
})

# ----- Strategies page -----
$window.FindName('cmbStrategyList').Add_SelectionChanged({
    $sel = $script:CmbStrategyList.SelectedItem
    if ($sel) {
        $info = ('ID: {0}    Имя: {1}' -f $sel.id, $sel.name)
        if ($sel.args) { $info += ("`r`n" + [string]$sel.args) }
        $script:TxtStrategyInfo.Text = $info
    }
})
function Get-SelectedStrategyId {
    $sel = $script:CmbStrategyList.SelectedItem
    if (-not $sel) { return $null }
    return [string]$sel.id
}
$window.FindName('btnInstallStrategy').Add_Click({
    $id = Get-SelectedStrategyId
    if (-not $id) { Show-ControlError 'Сначала выберите стратегию в списке.'; return }
    if (-not (Confirm-ControlAction ('Установить стратегию «{0}» службой zapret? Служба будет перезапущена.' -f $id))) { return }
    Start-ControlAction -Title ('Установка стратегии {0}' -f $id) -Action {
        param($StrategyId)
        Initialize-UserLists | Out-Null
        Install-ZapretService -StrategyId $StrategyId
    } -ArgumentList @($id)
})
$window.FindName('btnRunStrategy').Add_Click({
    $id = Get-SelectedStrategyId
    if (-not $id) { Show-ControlError 'Сначала выберите стратегию в списке.'; return }
    if (-not (Confirm-ControlAction ('Запустить winws.exe вручной со стратегией «{0}»? Это временный режим до нажатия «Остановить» или перезагрузки.' -f $id))) { return }
    Start-ControlAction -Title ('Ручной запуск {0}' -f $id) -Action {
        param($StrategyId)
        $strategy = Get-Strategy -Id $StrategyId
        if (-not $strategy) { throw ('Стратегия не найдена: {0}' -f $StrategyId) }
        $result = Start-ZapretManualRun -Strategy $strategy
        if ($result.Started) {
            Write-Host ('winws.exe запущен и работает (PID {0}). Служба не используется; остановите кнопкой «Остановить ручной запуск».' -f $result.Pid) -ForegroundColor Green
        } else {
            Write-Host ('Не удалось запустить winws.exe. {0}' -f $result.Error) -ForegroundColor Red
            Write-Host 'Частые причины: антивирус, конфликт WinDivert с другими обходами, нет прав администратора. Подробности — «Дополнительно» → «Диагностика».' -ForegroundColor DarkGray
        }
    } -ArgumentList @($id)
})
$window.FindName('btnStopRun').Add_Click({
    if (-not (Confirm-ControlAction 'Остановить winws.exe (ручной запуск)?')) { return }
    Start-ControlAction -Title 'Остановка ручного запуска' -Action {
        [void](Stop-Zapret)
        Write-Host 'Ручной запуск остановлен.' -ForegroundColor Green
    }
})
$window.FindName('btnStrategyTest').Add_Click({
    try {
        $tester = Join-Path $script:AppRoot 'utils\test zapret.ps1'
        if (-not (Test-Path -LiteralPath $tester -PathType Leaf)) { throw 'Не найден utils\test zapret.ps1.' }
        Start-Process -FilePath (Get-WindowsSystemToolPath -Name 'powershell.exe') -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $tester) -WorkingDirectory $script:AppRoot -WindowStyle Minimized | Out-Null
        Add-ControlActivity -Message 'Тест стратегий запущен в отдельном окне.'
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnStrategyClone').Add_Click({
    $base = Show-ControlInputDialog -Title 'Копия стратегии' -Message 'ID исходной стратегии (например, general):' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($base)) { return }
    $newId = Show-ControlInputDialog -Title 'Копия стратегии' -Message 'Новый ID (строчные латинские буквы, цифры и дефис):'
    if ([string]::IsNullOrWhiteSpace($newId)) { return }
    Start-ControlAction -Title 'Создание копии стратегии' -Action {
        param($BaseId, $NewId)
        [void](New-UserStrategy -BaseId $BaseId -NewId $NewId)
        Write-Host ('Создана пользовательская стратегия. Настройте её параметры кнопками ниже.' ) -ForegroundColor Green
    } -ArgumentList @($base.Trim(), $newId.Trim())
})
$window.FindName('btnStrategyImport').Add_Click({
    $code = Show-ControlInputDialog -Title 'Импорт стратегии' -Message 'Вставьте код стратегии zapret1:...'
    if ([string]::IsNullOrWhiteSpace($code)) { return }
    Start-ControlAction -Title 'Импорт стратегии' -Action {
        param($ShareString)
        $imported = Import-UserStrategy -ShareString $ShareString
        Write-Host ('Импортирована стратегия: {0}' -f $imported.id) -ForegroundColor Green
        Write-Host 'Установить её службой можно кнопкой «Установить службой» на странице «Стратегии».'
    } -ArgumentList @($code.Trim())
})
$window.FindName('btnStrategyExport').Add_Click({
    $id = Show-ControlInputDialog -Title 'Экспорт стратегии' -Message 'ID стратегии для экспорта:' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    Start-ControlAction -Title 'Экспорт стратегии' -Action {
        param($StrategyId)
        [void](Export-UserStrategy -Id $StrategyId)
    } -ArgumentList @($id.Trim())
})
$window.FindName('btnEditRepeats').Add_Click({
    $id = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'ID пользовательской стратегии для изменения (repeats):' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $value = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'Введите новое число повторов (целое число):'
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $intValue = 0
    if (-not [int]::TryParse($value.Trim(), [ref]$intValue)) { Show-ControlError 'Введите целое число.'; return }
    Start-ControlAction -Title 'Параметр repeats' -Action {
        param($StrategyId, $ParamValue)
        [void](Set-UserStrategyParam -Id $StrategyId -Param repeats -Value $ParamValue)
        Write-Host 'Параметр repeats обновлён.' -ForegroundColor Green
    } -ArgumentList @($id.Trim(), $intValue)
})
$window.FindName('btnEditSplitPos').Add_Click({
    $id = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'ID пользовательской стратегии для изменения (split-pos):' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $value = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'Введите новую позицию разделения (целое число):'
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $intValue = 0
    if (-not [int]::TryParse($value.Trim(), [ref]$intValue)) { Show-ControlError 'Введите целое число.'; return }
    Start-ControlAction -Title 'Параметр split-pos' -Action {
        param($StrategyId, $ParamValue)
        [void](Set-UserStrategyParam -Id $StrategyId -Param split-pos -Value $ParamValue)
        Write-Host 'Параметр split-pos обновлён.' -ForegroundColor Green
    } -ArgumentList @($id.Trim(), $intValue)
})
$window.FindName('btnEditSeqovl').Add_Click({
    $id = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'ID пользовательской стратегии для изменения (split-seqovl):' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $value = Show-ControlInputDialog -Title 'Настройка стратегии' -Message 'Введите новое перекрытие сегментов (целое число):'
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $intValue = 0
    if (-not [int]::TryParse($value.Trim(), [ref]$intValue)) { Show-ControlError 'Введите целое число.'; return }
    Start-ControlAction -Title 'Параметр seqovl' -Action {
        param($StrategyId, $ParamValue)
        [void](Set-UserStrategyParam -Id $StrategyId -Param seqovl -Value $ParamValue)
        Write-Host 'Параметр seqovl обновлён.' -ForegroundColor Green
    } -ArgumentList @($id.Trim(), $intValue)
})
$window.FindName('btnEditStrategyFake').Add_Click({
    $id = Show-ControlInputDialog -Title 'Фейк стратегии' -Message 'ID пользовательской стратегии:' -DefaultValue ([string](Get-SelectedStrategyId))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $fake = Show-ControlInputDialog -Title 'Фейк стратегии' -Message 'Имя файла из папки bin (без .bin):'
    if ([string]::IsNullOrWhiteSpace($fake)) { return }
    Start-ControlAction -Title 'Смена фейка стратегии' -Action {
        param($StrategyId, $FakeBaseName)
        [void](Set-UserStrategyFake -Id $StrategyId -FakeBaseName $FakeBaseName)
        Write-Host ('Фейк стратегии обновлён: {0}' -f $FakeBaseName) -ForegroundColor Green
    } -ArgumentList @($id.Trim(), $fake.Trim())
})

# ----- Network page -----
$window.FindName('btnDnsShow').Add_Click({
    Start-ControlAction -Title 'DNS-настройки' -Action { Write-DnsStatus }
})
$window.FindName('btnDohApply').Add_Click({
    $providers = @('cloudflare', 'google', 'quad9', 'adguard', 'yandex')
    $provider = $providers[[int]$script:CmbDohProvider.SelectedIndex]
    if (-not (Confirm-ControlAction ('Включить DoH и указать DNS провайдера ({0})? Изменение обратимо: «Вернуть DNS (DHCP)» или «Восстановить DNS из копии».' -f $provider))) { return }
    Start-ControlAction -Title ('DoH: {0}' -f $provider) -Action {
        param($ProviderName)
        Enable-Doh -Provider $ProviderName | Out-Null
    } -ArgumentList @($provider)
})
$window.FindName('btnDnsDhcp').Add_Click({
    if (-not (Confirm-ControlAction 'Вернуть автоматические настройки DNS (DHCP) на всех адаптерах?')) { return }
    Start-ControlAction -Title 'DNS: возврат к DHCP' -Action { Reset-DnsToDhcp | Out-Null }
})
$window.FindName('btnDnsRollback').Add_Click({
    if (-not (Confirm-ControlAction 'Восстановить DNS из последней резервной копии?')) { return }
    Start-ControlAction -Title 'DNS: восстановление из копии' -Action { [void](Restore-DnsRollbackSnapshot) }
})
$window.FindName('btnDnsBenchmark').Add_Click({
    if (-not (Confirm-ControlAction 'Сравнение займёт время и может сменить DNS на самый быстрый провайдер. Продолжить?')) { return }
    Start-ControlAction -Title 'Сравнение DNS-провайдеров' -Action { [void](Invoke-DnsBenchmark -ApplyFastest) }
})
$window.FindName('btnNetOptimize').Add_Click({
    if (-not (Confirm-ControlAction 'Применить сетевые настройки для меньшей задержки? Изменение можно отменить кнопкой «Отменить изменение сети».')) { return }
    Start-ControlAction -Title 'Сетевые настройки' -Action { [void](Invoke-NetworkOptimize) }
})
$window.FindName('btnNetRevert').Add_Click({
    if (-not (Confirm-ControlAction 'Отменить последнее изменение сетевых настроек?')) { return }
    Start-ControlAction -Title 'Отмена сетевого изменения' -Action { [void](Invoke-NetworkOptimize -Revert) }
})
$window.FindName('btnMtuCheck').Add_Click({
    Start-ControlAction -Title 'Проверка MTU' -Action { [void](Invoke-MtuCheck -NoPrompt) }
})
$window.FindName('btnPingTest').Add_Click({
    Start-ControlAction -Title 'Качество связи' -Action { [void](Invoke-LineQualityTest) }
})
$window.FindName('btnGameFilterApply').Add_Click({
    $modes = @('disabled', 'all', 'tcp', 'udp')
    $mode = $modes[[int]$script:CmbGameFilter.SelectedIndex]
    if (-not (Confirm-ControlAction 'Применить режим игрового трафика? Служба будет перезапущена.')) { return }
    Start-ControlAction -Title 'Игровой трафик' -Action {
        param($GameMode)
        [void](Update-Config @{ gameFilterMode = $GameMode })
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Игровой фильтр изменён')
    } -ArgumentList @($mode)
})
$window.FindName('btnGameTcp').Add_Click({
    $value = Show-ControlInputDialog -Title 'Порты TCP' -Message 'Диапазон портов (например, 1024-1934,1936-65535; по умолчанию 1024-65535):' -DefaultValue '1024-65535'
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    if (-not (Test-PortRange $value.Trim())) { Show-ControlError 'Диапазон портов указан неверно. Используйте числа от 1 до 65535, например 1024-65535.'; return }
    if (-not (Confirm-ControlAction 'Изменить порты TCP и перезапустить службу?')) { return }
    Start-ControlAction -Title 'Порты TCP' -Action {
        param($Range)
        [void](Update-Config @{ gameFilterTcp = $Range })
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Игровой фильтр изменён')
    } -ArgumentList @($value.Trim())
})
$window.FindName('btnGameUdp').Add_Click({
    $value = Show-ControlInputDialog -Title 'Порты UDP' -Message 'Диапазон портов (например, 1024-1934,1936-65535; по умолчанию 1024-65535):' -DefaultValue '1024-65535'
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    if (-not (Test-PortRange $value.Trim())) { Show-ControlError 'Диапазон портов указан неверно. Используйте числа от 1 до 65535, например 1024-65535.'; return }
    if (-not (Confirm-ControlAction 'Изменить порты UDP и перезапустить службу?')) { return }
    Start-ControlAction -Title 'Порты UDP' -Action {
        param($Range)
        [void](Update-Config @{ gameFilterUdp = $Range })
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Игровой фильтр изменён')
    } -ArgumentList @($value.Trim())
})

# ----- Sites page: manual domains -----
function Get-DomainInputValue {
    $value = [string]$script:TxtDomainInput.Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        Show-ControlError 'Введите домен или ссылку в поле выше.'
        return $null
    }
    return $value.Trim()
}
$window.FindName('btnDomainAdd').Add_Click({
    $value = Get-DomainInputValue
    if (-not $value) { return }
    Start-ControlAction -Title 'Добавление домена' -Action {
        param($Domain)
        [void](Add-DomainToList -Domain $Domain -Kind general)
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён')
    } -ArgumentList @($value)
})
$window.FindName('btnDomainExclude').Add_Click({
    $value = Get-DomainInputValue
    if (-not $value) { return }
    Start-ControlAction -Title 'Исключение домена' -Action {
        param($Domain)
        [void](Add-DomainToList -Domain $Domain -Kind exclude)
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён')
    } -ArgumentList @($value)
})
$window.FindName('btnDomainRemove').Add_Click({
    $value = Get-DomainInputValue
    if (-not $value) { return }
    Start-ControlAction -Title 'Удаление домена' -Action {
        param($Domain)
        $removed = Remove-DomainFromLists -Domain $Domain
        if ($removed.TotalRemoved -gt 0) {
            Write-Host ('Удалено записей: {0}' -f $removed.TotalRemoved) -ForegroundColor Green
            [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён')
        } else {
            Write-Host 'Домен не найден в ваших списках.' -ForegroundColor Yellow
        }
    } -ArgumentList @($value)
})
$window.FindName('btnDomainShow').Add_Click({
    Start-ControlAction -Title 'Мои списки доменов' -Action {
        $listsDir = Get-ZapretListsDir
        foreach ($pair in @(@('Сайты в списке обхода', (Join-Path $listsDir 'list-general-user.txt')), @('Исключения', (Join-Path $listsDir 'list-exclude-user.txt')))) {
            Write-Host ''
            Write-Host ('== {0} ==' -f $pair[0]) -ForegroundColor Cyan
            if (Test-Path -LiteralPath $pair[1]) {
                $lines = @(Get-Content -LiteralPath $pair[1] | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\s*#' -and $_.Trim([char]0xFEFF).Trim() -ne 'domain.example.abc' })
                if ($lines.Count -eq 0) { Write-Host '(список пуст)' -ForegroundColor DarkGray } else { $lines | ForEach-Object { Write-Host ('  ' + $_) } }
            } else { Write-Host '(список ещё не создан)' -ForegroundColor DarkGray }
        }
    }
})
$window.FindName('btnDomainNotepad').Add_Click({
    try {
        Initialize-UserLists | Out-Null
        $listsDir = Get-ZapretListsDir
        $notepadArgs = @(
            ('"{0}"' -f (Join-Path $listsDir 'list-general-user.txt')),
            ('"{0}"' -f (Join-Path $listsDir 'list-exclude-user.txt'))
        )
        Start-Process -FilePath (Get-WindowsSystemToolPath -Name 'notepad.exe') -ArgumentList ($notepadArgs -join ' ') | Out-Null
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnDomainReset').Add_Click({
    if (-not (Confirm-ControlAction 'Удалить все мои домены и восстановить пустые списки? IPSet и другие настройки не изменятся.')) { return }
    Start-ControlAction -Title 'Сброс моих списков' -Action {
        $reset = Reset-UserDomainLists
        if ($reset.Changed) {
            Write-Host 'Мои списки сброшены к пустым шаблонам.' -ForegroundColor Green
            [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов сброшен')
        } else {
            Write-Host 'Списки уже пусты.' -ForegroundColor DarkGray
        }
    }
})
$window.FindName('btnDomainDiscover').Add_Click({
    try {
        Start-Process -FilePath (Get-WindowsSystemToolPath -Name 'powershell.exe') -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" discover-domains' -f $script:CliPath) -WorkingDirectory $script:AppRoot -WindowStyle Normal | Out-Null
        Add-ControlActivity -Message 'Сбор доменов из DNS-кэша запущен в консоли.'
    } catch { Show-ControlError $_.Exception.Message }
})

# ----- More page -----
$window.FindName('btnSupportBundle').Add_Click({
    if (-not (Confirm-ControlAction 'Собрать отчёт для поддержки на Рабочем столе? Пути, IP и секреты маскируются; пользовательские стратегии не включаются.')) { return }
    Start-ControlAction -Title 'Отчёт для поддержки' -Action { [void](New-SupportBundle) }
})
function Install-ControlUpdate {
    # UI-thread dialog + background install. Start-ControlAction executes the
    # action as TEXT (no closures), so the manifest travels via -ArgumentList.
    param($Offer, [switch]$Auto)
    if (-not $Offer -or -not $Offer.Manifest) { return }
    if (-not $Auto) {
        $notes = @($Offer.Manifest.Notes | Select-Object -First 5) -join ("`n- ")
        $noteBlock = if ($notes) { ("`n`n- {0}" -f $notes) } else { '' }
        $answer = [System.Windows.MessageBox]::Show($script:Window, (
            'Доступно обновление {0} (установлено {1}).{2}`n`nСкачать и установить сейчас? Обход будет временно остановлен; настройки, списки и стратегии сохранятся. Потребуется подтверждение администратора.' -f $Offer.Remote, $Offer.Local, $noteBlock),
            'Обновление', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Start-ControlAction -Title ('Установка обновления {0}' -f $Offer.Remote) -Action {
        param($Manifest)
        $install = Install-ZapretUpdate -Manifest $Manifest -Relaunch
        if ($install.Ok) {
            Write-Host '  [i]  Приложение перезапущено — это окно можно закрыть.' -ForegroundColor Cyan
        } else {
            Write-Host ('  [X]  {0}' -f $install.Error) -ForegroundColor Red
            Write-Host '  [i]  Попробуйте снова кнопкой «Проверить обновления» или вручную: Update-Zapret.bat.' -ForegroundColor Yellow
        }
    } -ArgumentList @($Offer.Manifest)
}

$window.FindName('btnCheckUpdates').Add_Click({
    Start-UpdateOfferProbe -ShowDialog
})
$window.FindName('btnToggleUpdates').Add_Click({
    try {
        $cfg = Get-Config
        [void](Update-Config @{ checkUpdates = (-not $cfg.checkUpdates) })
        Add-ControlActivity -Message ('Проверка обновлений: {0}' -f $(if (-not $cfg.checkUpdates) { 'включена' } else { 'выключена' }))
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnToggleAutoInstall').Add_Click({
    try {
        $cfg = Get-Config
        [void](Update-Config @{ autoInstallUpdates = (-not $cfg.autoInstallUpdates) })
        Add-ControlActivity -Message ('Автоустановка обновлений: {0}' -f $(if (-not $cfg.autoInstallUpdates) { 'включена' } else { 'выключена' }))
        if (-not $cfg.autoInstallUpdates) {
            Add-ControlActivity -Message 'Источник автообновлений задаётся в config.json (поле updateFeed).'
        }
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message }
})

function Start-UpdateOfferProbe {
    # Non-blocking probe of the update feed (runs in a background runspace).
    # -ShowDialog: launched by the check button and reports with dialogs.
    param([switch]$ShowDialog)
    $script:UpdateProbeShowDialog = [bool]$ShowDialog
    if ($ShowDialog) { Add-ControlActivity -Message 'Проверяю обновления…' }
    if ($script:UpdateProbeAsync -and -not $script:UpdateProbeAsync.IsCompleted) {
        if ($ShowDialog) { Add-ControlActivity -Message 'Проверка обновлений уже выполняется — дождитесь результата.' }
        return
    }
    $runspace = $null
    $ps = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            param($ModulePath)
            Import-Module -Name $ModulePath -Force
            Get-ZapretUpdateOffer
        }.ToString()).AddArgument($script:ModulePath)
        $script:UpdateProbePs = $ps
        $script:UpdateProbeRunspace = $runspace
        $script:UpdateProbeAsync = $ps.BeginInvoke()
        $script:UpdateProbeTimer.Start()
    } catch {
        $msg = $_.Exception.Message
        Add-ControlActivity -Message ("Не удалось запустить проверку обновлений: {0}" -f $msg)
        if ($ShowDialog) { Show-ControlError ("Не удалось запустить проверку обновлений: {0}" -f $msg) }
        if ($ps) { try { $ps.Dispose() } catch { } }
        if ($runspace) { try { $runspace.Dispose() } catch { } }
    }
}

function Complete-UpdateOfferProbe {
    if (-not $script:UpdateProbeAsync -or -not $script:UpdateProbeAsync.IsCompleted) { return }
    $script:UpdateProbeTimer.Stop()
    $showDialog = [bool]$script:UpdateProbeShowDialog
    $script:UpdateProbeShowDialog = $false
    $offer = $null
    try { $offer = @($script:UpdateProbePs.EndInvoke($script:UpdateProbeAsync)) | Select-Object -First 1 } catch { }
    try { $script:UpdateProbePs.Dispose() } catch { }
    try { $script:UpdateProbeRunspace.Dispose() } catch { }
    $script:UpdateProbeAsync = $null

    if (-not $offer) {
        if ($showDialog) { Show-ControlError 'Проверка обновлений не выполнена (см. журнал).' }
        return
    }
    if (-not $offer.Configured) {
        if ($showDialog) {
            [void][System.Windows.MessageBox]::Show($script:Window, (
                "Источник автообновлений не настроен.`n`nЧтобы включить автообновления, укажите ссылку на update-manifest.json в config.json (поле updateFeed) — в вашем репозитории или на любом статическом хостинге. Формат манифеста лежит в папке программы: update-manifest.example.json.`n`nПроверка апстрима Flowseal доступна в консоли: zapret.ps1 check-updates"),
                'Проверка обновлений', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
        return
    }
    if ($offer.Error) {
        if ($showDialog) { Show-ControlError $offer.Error }
        return
    }
    if (-not $offer.UpdateAvailable) {
        if ($showDialog) {
            [void][System.Windows.MessageBox]::Show($script:Window, ('Установлена последняя версия ({0}).' -f $offer.Local), 'Проверка обновлений', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
        return
    }
    Add-ControlActivity -Message ('Доступно обновление {0} (установлено {1}).' -f $offer.Remote, $offer.Local)
    $autoInstall = $false
    try { $autoInstall = [bool](Get-Config).autoInstallUpdates } catch { }
    if ($showDialog) { Install-ControlUpdate -Offer $offer }
    elseif ($autoInstall) {
        Add-ControlActivity -Message ('Автоустановка: начинаю обновление до {0}…' -f $offer.Remote)
        Install-ControlUpdate -Offer $offer -Auto
    }
}
$window.FindName('btnRollback').Add_Click({
    $rb = $null
    try { $rb = (Get-Config).rollback } catch { }
    if ($null -eq $rb -or -not $rb.folder) {
        [void][System.Windows.MessageBox]::Show($script:Window, 'Резервных копий пока нет. Перед изменением стратегии, IP-списка или hosts программа сохранит копию для отката.', 'Откат', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    $message = ('Восстановить последнюю копию?{0}Создана: {1}{0}Причина: {2}' -f "`r`n", $rb.time, $rb.reason)
    if (-not (Confirm-ControlAction $message 'Восстановление из копии')) { return }
    Start-ControlAction -Title 'Восстановление из копии' -Action { [void](Restore-RollbackSnapshot) }
})
$window.FindName('btnExportConfig').Add_Click({
    Start-ControlAction -Title 'Резервная копия настроек' -Action {
        $exported = Export-ZapretConfig
        Write-Host ('Сохранено: {0} (файлов: {1})' -f $exported.Path, $exported.FileCount) -ForegroundColor Green
    }
})
$window.FindName('btnImportConfig').Add_Click({
    $path = Show-ControlInputDialog -Title 'Перенос настроек' -Message 'Путь к старой папке zapret (например, D:\zapret) или к zip-архиву резервной копии:'
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not (Confirm-ControlAction ('Перенести настройки из папки {0}? Настройки, списки, IP-список и фейки будут скопированы.' -f $path.Trim()))) { return }
    Start-ControlAction -Title 'Перенос настроек' -Action {
        param($SourcePath)
        [void](Import-ExternalConfig -SourcePath $SourcePath)
    } -ArgumentList @($path.Trim().Trim('"'))
})
$window.FindName('btnPause').Add_Click({
    $minutesText = Show-ControlInputDialog -Title 'Пауза обхода' -Message 'На сколько минут приостановить обход? (1–1440)' -DefaultValue '30'
    if ([string]::IsNullOrWhiteSpace($minutesText)) { return }
    $minutes = 0
    if (-not [int]::TryParse($minutesText.Trim(), [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) {
        Show-ControlError 'Введите целое число от 1 до 1440.'
        return
    }
    if (-not (Confirm-ControlAction ('Приостановить обход на {0} мин? Обход остановится и возобновится автоматически.' -f $minutes))) { return }
    Start-ControlAction -Title ('Пауза обхода: {0} мин' -f $minutes) -Action {
        param($Minutes)
        [void](Suspend-ZapretBypass -Minutes $Minutes)
    } -ArgumentList @($minutes)
})
$window.FindName('btnScheduleToggle').Add_Click({
    try {
        if (Test-AutoSelectSchedule) {
            [void](Set-AutoSelectSchedule -Disable)
            Add-ControlActivity -Message 'Еженедельная перепроверка выключена.'
        } else {
            [void](Set-AutoSelectSchedule -Enable)
            Add-ControlActivity -Message 'Еженедельная перепроверка включена (воскресенье, 03:30).'
        }
        Refresh-ControlStatus
    } catch { Show-ControlError $_.Exception.Message }
})
$window.FindName('btnIpsetLoaded').Add_Click({
    if (-not (Confirm-ControlAction 'Изменить IP-фильтр: использовать загруженный список? Служба будет перезапущена.')) { return }
    Start-ControlAction -Title 'IP-фильтр: список' -Action {
        Set-IpsetMode -Mode loaded | Out-Null
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'IPSet изменён')
    }
})
$window.FindName('btnIpsetNone').Add_Click({
    if (-not (Confirm-ControlAction 'Изменить IP-фильтр: не фильтровать IP-адреса? Служба будет перезапущена.')) { return }
    Start-ControlAction -Title 'IP-фильтр: выкл' -Action {
        Set-IpsetMode -Mode none | Out-Null
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'IPSet изменён')
    }
})
$window.FindName('btnIpsetAny').Add_Click({
    if (-not (Confirm-ControlAction 'Изменить IP-фильтр: фильтровать все адреса (может помешать сайтам)? Служба будет перезапущена.')) { return }
    Start-ControlAction -Title 'IP-фильтр: все адреса' -Action {
        Set-IpsetMode -Mode any | Out-Null
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'IPSet изменён')
    }
})
$window.FindName('btnIpsetUpdate').Add_Click({
    if (-not (Confirm-ControlAction 'Обновить список IP-адресов из сети?')) { return }
    Start-ControlAction -Title 'Обновление списка IP' -Action { Update-IpsetList | Out-Null }
})
$window.FindName('btnHostsUpdate').Add_Click({
    if (-not (Confirm-ControlAction 'Обновить управляемый блок в файле hosts? Перед изменением создаётся резервная копия.')) { return }
    Start-ControlAction -Title 'Обновление hosts' -Action { Update-HostsFile | Out-Null }
})
$window.FindName('btnFakeDiscordApply').Add_Click({
    $sel = $script:CmbFakesDiscord.SelectedItem
    if (-not $sel) { Show-ControlError 'Сначала выберите файл в списке.'; return }
    $fakeName = [string]$sel.BaseName
    if (-not (Confirm-ControlAction ('Использовать файл «{0}» для подмены UDP Discord? Служба будет перезапущена.' -f $fakeName))) { return }
    Start-ControlAction -Title 'Фейк для Discord' -Action {
        param($FakeBaseName)
        Set-ActiveFake -Target discord -FakeBaseName $FakeBaseName
        Write-Host ('Фейк для Discord обновлён: {0}' -f $FakeBaseName) -ForegroundColor Green
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Фейки заменены')
    } -ArgumentList @($fakeName)
})
$window.FindName('btnFakeGameApply').Add_Click({
    $sel = $script:CmbFakesGame.SelectedItem
    if (-not $sel) { Show-ControlError 'Сначала выберите файл в списке.'; return }
    $fakeName = [string]$sel.BaseName
    if (-not (Confirm-ControlAction ('Использовать файл «{0}» для подмены UDP в играх? Служба будет перезапущена.' -f $fakeName))) { return }
    Start-ControlAction -Title 'Фейк для игр' -Action {
        param($FakeBaseName)
        Set-ActiveFake -Target game -FakeBaseName $FakeBaseName
        Write-Host ('Фейк для игр обновлён: {0}' -f $FakeBaseName) -ForegroundColor Green
        [void](Invoke-ZapretServiceRestartPrompt -Reason 'Фейки заменены')
    } -ArgumentList @($fakeName)
})
$window.FindName('btnUninstall').Add_Click({
    if (-not (Confirm-ControlAction 'Удалить службы zapret и WinDivert и остановить winws.exe? Это действие нельзя отменить.' 'Удаление установки')) { return }
    $removeHosts = Confirm-ControlAction 'Также удалить управляемый блок из файла hosts?' 'Удаление установки'
    Start-ControlAction -Title 'Удаление установки' -Action {
        param([bool]$RemoveHosts)
        [void](Remove-ZapretServices -Quiet -RemoveHostsBlock:$RemoveHosts)
    } -ArgumentList @([bool]$removeHosts)
})

$script:StatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:StatusTimer.Interval = [TimeSpan]::FromSeconds(8)
$script:StatusTimer.Add_Tick({ Refresh-ControlStatus })
$script:WizardTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WizardTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:WizardTimer.Add_Tick({ Update-WizardProgress })
$script:UpdateProbeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdateProbeTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:UpdateProbeTimer.Add_Tick({ Complete-UpdateOfferProbe })
$window.Add_ContentRendered({
    Refresh-ControlStatus
    $script:StatusTimer.Start()
    try { if ((Get-Config).checkUpdates) { Start-UpdateOfferProbe } } catch { Start-UpdateOfferProbe }
    $shortcutState = Get-ControlShortcutState
    if (-not $shortcutState.Asked) {
        $answer = [System.Windows.MessageBox]::Show($window, 'Создать ярлык "OpenZapret" на рабочем столе? Ярлык с иконкой запускает приложение сразу, без консольного окна.', 'Ярлык приложения', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                $link = Install-ControlShortcut
                Add-ControlActivity -Message ('Ярлык создан: {0}' -f $link)
            } catch { Show-ControlError $_.Exception.Message }
        }
        try { Set-ControlShortcutAsked } catch { }
    }
})
$window.Add_Closed({ $script:StatusTimer.Stop(); $script:WizardTimer.Stop(); try { if ($script:WizardPs) { $script:WizardPs.Stop() } } catch { } })
[void]$window.ShowDialog()

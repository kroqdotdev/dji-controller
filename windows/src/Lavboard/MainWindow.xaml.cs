using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Lavboard.Controls;
using Lavboard.Core;
using Lavboard.Model;
using Lavboard.Views;

namespace Lavboard;

/// <summary>The one window: everything the macOS ContentView shows, in the same order.</summary>
public sealed partial class MainWindow : Window
{
    /// <summary>The macOS window's default size including its 52 pt toolbar, and its content's minimum height, in DIPs.</summary>
    private const double DefaultWidth = 1360, DefaultHeight = 780, MinimumHeight = 700;

    private readonly AppModel app;
    private readonly Desk desk;
    private readonly Button modeButton;
    private readonly TextBlock modeText = new();
    private readonly Button settingsButton;

    public MainWindow(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragArea);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        StyleCaptionButtons();

        desk = new Desk(app);
        Grid.SetRow(desk, 2);
        Root.Children.Add(desk);
        var transport = new TransportBar(app);
        transport.ChooseFolder += async (_, _) => await ChooseFolder();
        transport.ShowFolder += (_, _) => { if (app.LastRecordingFolder is { } folder) _ = Launcher.LaunchFolderPathAsync(folder); };
        Grid.SetRow(transport, 3);
        Root.Children.Add(transport);

        // The Mac's toolbar Menu: the name with a small chevron right after it.
        modeButton = new Button
        {
            Style = (Style)Application.Current.Resources["ToolbarButton"],
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 4,
                Children = { modeText, new FontIcon { Glyph = "", FontSize = 8, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Margin = new Thickness(0, 2, 0, 0) } },
            },
        };
        var modeMenu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        modeMenu.Opening += (_, _) => FillModes(modeMenu);
        modeButton.Flyout = modeMenu;
        settingsButton = new Button { Content = "Settings", Style = (Style)Application.Current.Resources["ToolbarButton"] };
        settingsButton.Flyout = new Flyout
        {
            Placement = FlyoutPlacementMode.Bottom, ShouldConstrainToRootBounds = false, FlyoutPresenterStyle = (Style)Application.Current.Resources["PopoverPresenter"],
            Content = new SettingsView(app),
        };
        Toolbar.Children.Add(modeButton);
        Toolbar.Children.Add(settingsButton);

        AddMuteKeys();
        app.PropertyChanged += OnAppChanged;
        foreach (var system in app.MicSystems) system.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(Refresh);
        app.Engine.Changed += (_, _) => DispatcherQueue.TryEnqueue(Refresh);
        app.Tracks.CollectionChanged += (_, _) => { Refresh(); ApplyMinimumSize(); };

        SizeWindow();
        Refresh();
    }

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        TitleText.Text = app.Title;
        SubtitleText.Text = app.Subtitle;
        Title = app.Title == "Lavboard" ? "Lavboard" : $"Lavboard: {app.Title}";
        RefreshMode();
        RefreshBanners();
    }

    // MARK: Window

    private double GetDpiScale() => GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);

    /// <summary>Opens at the macOS default size, shrunk to fit smaller screens, and centred.</summary>
    private void SizeWindow()
    {
        double scale = GetDpiScale();
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        // The outer size includes invisible resize borders. ResizeClient would also add the system
        // title bar the content already covers, so size the outer window from the measured frame.
        int frameWidth = AppWindow.Size.Width - AppWindow.ClientSize.Width;
        int frameHeight = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        int width = (int)Math.Min(DefaultWidth * scale, area.Width - frameWidth);
        int height = (int)Math.Min(DefaultHeight * scale, area.Height - frameHeight);
        AppWindow.Resize(new SizeInt32(width + frameWidth, height + frameHeight));
        var size = AppWindow.Size;
        AppWindow.Move(new PointInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2));
        ApplyMinimumSize();
        Root.Loaded += (_, _) => UpdateCaptionInset();
        AppWindow.Changed += (_, e) => { if (e.DidSizeChange) UpdateCaptionInset(); };
    }

    private void ApplyMinimumSize()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        double scale = GetDpiScale();
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        presenter.PreferredMinimumWidth = (int)Math.Min(DeskLayout.MinimumWidth(app.Tracks.Count) * scale, area.Width);
        presenter.PreferredMinimumHeight = (int)Math.Min((MinimumHeight + 52) * scale, area.Height);
    }

    /// <summary>Keeps the toolbar clear of the minimise, maximise and close buttons.</summary>
    private void UpdateCaptionInset()
    {
        double scale = GetDpiScale();
        CaptionInset.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
    }

    private void StyleCaptionButtons()
    {
        var bar = AppWindow.TitleBar;
        var silk = (Windows.UI.Color)Application.Current.Resources["ConsoleSilkColor"];
        var engraving = (Windows.UI.Color)Application.Current.Resources["ConsoleEngravingColor"];
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = silk;
        bar.ButtonInactiveForegroundColor = engraving;
        bar.ButtonHoverBackgroundColor = Windows.UI.Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF);
        bar.ButtonHoverForegroundColor = silk;
        bar.ButtonPressedBackgroundColor = Windows.UI.Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF);
        bar.ButtonPressedForegroundColor = silk;
    }

    // MARK: Receiver mode

    private IMicSystem? ModeSystem => app.MicSystems.FirstOrDefault(s => s.IsConnected && !s.IsSwitchingMode && s.Modes.Any(m => m.Id == s.CurrentModeId));

    private void RefreshMode()
    {
        var system = ModeSystem;
        modeButton.Visibility = system == null ? Visibility.Collapsed : Visibility.Visible;
        if (system == null) return;
        modeText.Text = system.Modes.First(m => m.Id == system.CurrentModeId).Name;
        modeButton.IsEnabled = !app.IsRecording;
        ToolTipService.SetToolTip(modeButton, $"{system.Name} receiver mode");
    }

    private void FillModes(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (ModeSystem is not { } system) return;
        foreach (var mode in system.Modes)
        {
            bool current = mode.Id == system.CurrentModeId;
            var item = new ToggleMenuFlyoutItem { Text = mode.Name, IsChecked = current, IsEnabled = !current };
            item.Click += async (_, _) => await SwitchMode(system, mode.Id);
            menu.Items.Add(item);
        }
    }

    /// <summary>Switches straight away, or asks first if the module warns about the switch.</summary>
    private async Task SwitchMode(IMicSystem system, string id)
    {
        if (system.Modes.FirstOrDefault(m => m.Id == id) is not { } mode) return;
        if (system.ModeSwitchWarning(id) is { } warning)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = $"Switch the receiver to {mode.Name}?", Content = warning,
                PrimaryButtonText = "Switch", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
                RequestedTheme = ElementTheme.Dark,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        system.SetMode(id);
    }

    // MARK: Banners

    private void RefreshBanners()
    {
        Banners.Children.Clear();
        foreach (var system in app.MicSystems)
        {
            if (system.Notice is not { } notice || !app.Tracks.Any(t => t.Source is TransmitterSource ts && ts.System == system.Id)) continue;
            Button? action = null;
            if (notice.ActionTitle is { } title && notice.ModeId is { } modeId)
            {
                action = new Button { Content = title, IsEnabled = !app.IsRecording, FontSize = 13 };
                action.Click += async (_, _) => await SwitchMode(system, modeId);
            }
            Banners.Children.Add(Banner(notice.Message, action));
        }
    }

    private static Border Banner(string message, Button? action)
    {
        var row = new Grid { ColumnSpacing = 14, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        row.Children.Add(new TextBlock { Text = message, FontSize = 13, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Foreground = LedMeter.Brush("ConsoleSilk") });
        if (action != null)
        {
            Grid.SetColumn(action, 1);
            row.Children.Add(action);
        }
        return new Border { Background = LedMeter.Brush("ConsolePanel"), Padding = new Thickness(16, 10, 16, 10), Child = row };
    }

    // MARK: Keys and folders

    /// <summary>1 to 8 mute the matching track, as on the Mac, unless a text field has focus.</summary>
    private void AddMuteKeys()
    {
        for (int i = 0; i < Track.Maximum; i++)
        {
            int index = i;
            foreach (var key in new[] { VirtualKey.Number1 + i, VirtualKey.NumberPad1 + i })
            {
                var accelerator = new KeyboardAccelerator { Key = key };
                accelerator.Invoked += (_, e) =>
                {
                    if (FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox) return;
                    e.Handled = true;
                    app.ToggleMute(index);
                };
                Root.KeyboardAccelerators.Add(accelerator);
            }
        }
        Root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
    }

    private async Task ChooseFolder()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker { CommitButtonText = "Use folder" };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) app.RecordingFolder = folder.Path;
    }
}

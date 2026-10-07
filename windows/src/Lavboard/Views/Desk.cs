using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Lavboard.Controls;
using Lavboard.Core;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>
/// The strips, the add slot and the two output strips. Strip widths follow the macOS Desk: roomy
/// with few tracks, compact (row labels become tooltips) when the desk is full.
/// </summary>
public sealed partial class Desk : UserControl
{
    private const double Gap = DeskLayout.Gap, SpacerMin = DeskLayout.SpacerMin;

    private readonly AppModel app;
    private readonly Grid grid = new() { ColumnSpacing = Gap, Padding = new Thickness(DeskLayout.PaddingX, DeskLayout.PaddingY, DeskLayout.PaddingX, DeskLayout.PaddingY) };
    private readonly List<TrackStrip> strips = [];
    private readonly AddTrackSlot addSlot = new() { Width = DeskLayout.AddSlotWidth, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Stretch };
    private readonly FrameworkElement empty;
    public MasterStrip Stream { get; }
    public MasterStrip Venue { get; }

    public Desk(AppModel app)
    {
        this.app = app;
        Stream = new MasterStrip(app, "Stream", () => app.StreamOutputId, id => app.StreamOutputId = id,
                                 () => app.StreamLevelDb, db => app.StreamLevelDb = db);
        Venue = new MasterStrip(app, "Venue", () => app.VenueOutputId, id => app.VenueOutputId = id,
                                () => app.VenueLevelDb, db => app.VenueLevelDb = db);
        addSlot.Click += (_, _) => SourcePicker.Show(app, addSlot);
        empty = EmptyDesk();
        Content = grid;

        app.Tracks.CollectionChanged += OnTracksChanged;
        app.PropertyChanged += OnAppChanged;
        app.MetersUpdated += (_, _) => ShowMeters();
        // The venue note shows the latency the engine reports once it has rebuilt for the output.
        app.Engine.Changed += (_, _) => DispatcherQueue.TryEnqueue(RefreshNotes);
        SizeChanged += (_, _) => Place();
        Rebuild();
    }

    private void OnTracksChanged(object? sender, NotifyCollectionChangedEventArgs e) => Rebuild();

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.AnyStereo): Place(); break;
            case nameof(AppModel.CanAddTrack): Rebuild(); break;
            case nameof(AppModel.StreamOutputId) or nameof(AppModel.StreamLevelDb): Stream.Refresh(); break;
            case nameof(AppModel.VenueOutputId) or nameof(AppModel.VenueLevelDb): Venue.Refresh(); RefreshNotes(); break;
        }
    }

    /// <summary>Strips are kept per track, so a reorder moves them instead of rebuilding them.</summary>
    private void Rebuild()
    {
        var keep = strips.Where(s => app.Tracks.Contains(s.Track)).ToDictionary(s => s.Track);
        foreach (var gone in strips.Where(s => !keep.ContainsKey(s.Track))) gone.Detach();
        strips.Clear();
        foreach (var track in app.Tracks) strips.Add(keep.TryGetValue(track, out var strip) ? strip : new TrackStrip(app, track));

        grid.Children.Clear();
        grid.ColumnDefinitions.Clear();
        int column = 0;
        void Add(FrameworkElement element, GridLength width)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            Grid.SetColumn(element, column++);
            grid.Children.Add(element);
        }
        if (strips.Count == 0)
        {
            Add(empty, new GridLength(1, GridUnitType.Star));
        }
        else
        {
            foreach (var strip in strips) Add(strip, GridLength.Auto);
            if (app.CanAddTrack) Add(addSlot, GridLength.Auto);
            // Pushes the outputs to the right edge (SwiftUI's Spacer(minLength: 14)).
            var spacer = new Border();
            Add(spacer, new GridLength(1, GridUnitType.Star));
            grid.ColumnDefinitions[^1].MinWidth = SpacerMin;
        }
        Add(Stream, GridLength.Auto);
        Add(Venue, GridLength.Auto);
        RefreshNotes();
        Place();
    }

    private void Place()
    {
        if (ActualWidth <= 0) return;
        double width = DeskLayout.StripWidth(ActualWidth, app.Tracks.Count, app.CanAddTrack);
        bool compact = DeskLayout.IsCompact(width);
        for (int i = 0; i < strips.Count; i++) strips[i].Place(i, width, compact, app.AnyStereo);
    }

    private void ShowMeters()
    {
        foreach (var strip in strips) strip.ShowMeters(app.Meters);
        Stream.ShowMeter(app.Meters.Stream);
        Venue.ShowMeter(app.Meters.Venue);
    }

    public void RefreshNotes()
    {
        // Windows has no Lavboard stream device yet; the stream mix goes to any output, such as VB-CABLE.
        Stream.ShowNote(app.StreamOutputId == null ? "Pick the output Streamlabs listens to" : null);
        Venue.ShowNote(app.VenueOutputId != null && app.Engine.VenueLatencyMs is double ms ? $"Adds {ms:0.0} ms" : null);
    }

    private FrameworkElement EmptyDesk()
    {
        var slot = new AddTrackSlot { Width = 140, Height = 120, HorizontalAlignment = HorizontalAlignment.Center };
        slot.Click += (_, _) => SourcePicker.Show(app, slot, FlyoutPlacementMode.Bottom);
        return new StackPanel
        {
            Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock
                {
                    Text = "Add a track to start mixing", FontFamily = (FontFamily)Application.Current.Resources["InterSemiBold"],
                    FontWeight = FontWeights.SemiBold, FontSize = 20, Foreground = LedMeter.Brush("ConsoleSilk"), HorizontalAlignment = HorizontalAlignment.Center,
                },
                new TextBlock
                {
                    Text = "Pick a DJI transmitter, a USB mic or any other input on this PC.", FontSize = 13,
                    Foreground = LedMeter.Brush("ConsoleEngraving"), HorizontalAlignment = HorizontalAlignment.Center,
                },
                slot,
            },
        };
    }
}

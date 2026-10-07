using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Lavboard.Model;

namespace Lavboard.Views;

/// <summary>Right-click menu for a track strip, rebuilt each time it opens so it reflects the current state.</summary>
public static class TrackMenu
{
    public static MenuFlyout Create(AppModel app, Track track, Action rename)
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => Fill(menu, app, track, rename);
        return menu;
    }

    private static void Fill(MenuFlyout menu, AppModel app, Track track, Action rename)
    {
        menu.Items.Clear();
        int i = app.Tracks.IndexOf(track);
        if (i < 0) return;
        bool editable = app.CanEditTracks;

        menu.Items.Add(Item("Rename…", rename));

        var colour = new MenuFlyoutSubItem { Text = "Colour" };
        foreach (var color in Enum.GetValues<TapeColor>())
        {
            var item = new RadioMenuFlyoutItem { Text = color.Label(), GroupName = "tape", IsChecked = track.Color == color };
            item.Click += (_, _) => track.Color = color;
            colour.Items.Add(item);
        }
        menu.Items.Add(colour);

        var source = new MenuFlyoutSubItem { Text = "Source", IsEnabled = editable };
        SourceMenu.Fill(source.Items, app, track.Source, s => app.SetSource(track, s));
        menu.Items.Add(source);

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(track.Muted ? "Unmute" : "Mute", () => app.ToggleMute(app.Tracks.IndexOf(track))));
        var venue = new ToggleMenuFlyoutItem { Text = "Send to venue", IsChecked = track.SendToVenue };
        venue.Click += (_, _) => track.SendToVenue = venue.IsChecked;
        menu.Items.Add(venue);
        menu.Items.Add(Item("Reset fader to 0 dB", () => track.FaderDb = 0, track.FaderDb != 0));

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Move left", () => app.MoveTrack(track, -1), editable && i > 0));
        menu.Items.Add(Item("Move right", () => app.MoveTrack(track, 1), editable && i < app.Tracks.Count - 1));

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Remove track", () => app.RemoveTrack(track), editable));
    }

    public static MenuFlyoutItem Item(string text, Action action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => action();
        return item;
    }
}

/// <summary>Menu items for every source a track can use, grouped like the macOS menu's sections.</summary>
public static class SourceMenu
{
    public static void Fill(IList<MenuFlyoutItemBase> items, AppModel app, TrackSource current, Action<TrackSource> pick)
    {
        items.Clear();
        void Section(string title, IEnumerable<SourceChoice> choices)
        {
            if (items.Count > 0) items.Add(new MenuFlyoutSeparator());
            items.Add(new MenuFlyoutItem { Text = title, IsEnabled = false, FontSize = 11 });
            foreach (var choice in choices)
            {
                var item = new RadioMenuFlyoutItem
                {
                    Text = choice.Title, GroupName = "source", IsChecked = choice.Source == current,
                    IsEnabled = !choice.InUse || choice.Source == current,
                };
                item.Click += (_, _) => pick(choice.Source);
                items.Add(item);
            }
        }
        foreach (var group in app.SourceChoices()) Section(group.Title, group.Options);
        Section("App audio", app.AppAudioChoices());
    }
}

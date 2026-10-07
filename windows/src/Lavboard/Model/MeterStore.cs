namespace Lavboard.Model;

/// <summary>
/// Display levels for every meter, refreshed 30 times a second from the audio core. Instant
/// attack, 24 dB/s release, a 1.5 s peak hold and a 2 s clip latch, as in the macOS app.
/// </summary>
public sealed class MeterStore
{
    public struct Level
    {
        public float Db;
        public float Hold;
        internal DateTime HoldUntil;
        internal DateTime ClipUntil;

        public static Level Silent => new() { Db = -120, Hold = -120 };
        public readonly bool Clipping => ClipUntil > DateTime.UtcNow;

        internal void Feed(float peak, float dt, DateTime now)
        {
            float db = peak > 0 ? 20 * MathF.Log10(peak) : -120;
            Db = Math.Max(db, Db - 24 * dt);
            if (db >= Hold || now > HoldUntil)
            {
                Hold = Math.Max(db, Hold - 24 * dt);
                if (db >= Hold) HoldUntil = now.AddSeconds(1.5);
            }
            if (peak >= 0.999f) ClipUntil = now.AddSeconds(2);
        }
    }

    public Level[] Left { get; } = Enumerable.Repeat(Level.Silent, Track.Maximum).ToArray();
    public Level[] Right { get; } = Enumerable.Repeat(Level.Silent, Track.Maximum).ToArray();
    public Level Stream = Level.Silent;
    public Level Venue = Level.Silent;
    private DateTime last = DateTime.UtcNow;

    /// <summary>Feeds peaks since the previous read (linear, 0...1).</summary>
    public void Update(ReadOnlySpan<float> left, ReadOnlySpan<float> right, float stream, float venue)
    {
        var now = DateTime.UtcNow;
        float dt = (float)Math.Min((now - last).TotalSeconds, 0.25);
        last = now;
        for (int i = 0; i < Track.Maximum; i++)
        {
            Left[i].Feed(i < left.Length ? left[i] : 0, dt, now);
            Right[i].Feed(i < right.Length ? right[i] : 0, dt, now);
        }
        Stream.Feed(stream, dt, now);
        Venue.Feed(venue, dt, now);
    }
}

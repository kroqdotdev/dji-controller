using System.Buffers.Binary;
using System.Globalization;
using Lavboard.Core;
using Lavboard.Core.Interop;
using Lavboard.MicSystems;
using Lavboard.Model;

// LavProbe: drives Lavboard's engine from the command line, for testing with real devices.
//
//   LavProbe devices
//   LavProbe apps
//   LavProbe tone <out.wav> [--freq 1000] [--seconds 10] [--level -12]
//   LavProbe run [--track dev=<name>:<channel>[s]] [--track app=<exe>] [--track system] [--no-venue <track>]
//                [--fader <track>=<dB>] [--venue <name>] [--stream <name>] [--seconds 10] [--period 64]
//                [--record <folder>] [--float] [--rebuild-at <seconds>]
//   LavProbe analyze <file.wav> [--freq 1000] [--channel 0]
//
// Device names match by substring, case-insensitively. Output goes to the console and, with
// --log <file>, to a file as well (useful when run on the desktop session through a scheduler).

var arguments = args.ToList();
string? logPath = Option(arguments, "--log");
using var log = logPath == null ? null : new StreamWriter(logPath, append: false) { AutoFlush = true };
void Say(string line)
{
    Console.WriteLine(line);
    log?.WriteLine(line);
}

try
{
    switch (arguments.FirstOrDefault())
    {
        case "devices":
            foreach (var d in AudioDevices.List())
            {
                string usb = d.UsbVendor != 0 ? $" usb {d.UsbVendor:X4}:{d.UsbProduct:X4}" : "";
                Say($"{(d.IsInput ? "in " : "out")} {d.Name} | {d.Channels} ch {d.SampleRate} Hz{(d.IsDefault ? " default" : "")}{usb}{(d.IsBluetooth ? " bluetooth" : "")}");
                Say($"    {d.Id}");
            }
            return 0;
        case "apps":
            foreach (var app in AudioApps.List()) Say($"{app.AppId} | {app.Name}{(app.Playing ? " | playing" : "")} | pid {AudioApps.ProcessFor(app.AppId)}");
            return 0;
        case "tone":
            return Tone(arguments.Skip(1).ToList());
        case "run":
            return Run(arguments.Skip(1).ToList());
        case "analyze":
            return Analyze(arguments.Skip(1).ToList());
        default:
            Say("usage: LavProbe devices | apps | tone <out.wav> | run [options] | analyze <file.wav>");
            return 2;
    }
}
catch (Exception e)
{
    Say($"error: {e}");
    return 1;
}

static string? Option(List<string> list, string name)
{
    int i = list.IndexOf(name);
    if (i < 0 || i + 1 >= list.Count) return null;
    string value = list[i + 1];
    list.RemoveRange(i, 2);
    return value;
}

static List<string> Options(List<string> list, string name)
{
    var values = new List<string>();
    while (Option(list, name) is { } value) values.Add(value);
    return values;
}

static double Number(List<string> list, string name, double fallback) =>
    Option(list, name) is { } text ? double.Parse(text, CultureInfo.InvariantCulture) : fallback;

int Tone(List<string> a)
{
    double freq = Number(a, "--freq", 1000), seconds = Number(a, "--seconds", 10), level = Number(a, "--level", -12);
    string path = a.FirstOrDefault() ?? throw new ArgumentException("tone needs an output path");
    const int rate = 48_000;
    float amplitude = (float)Math.Pow(10, level / 20);
    using var wav = new WavWriter(path, 2, rate, RecordingFormat.Pcm24);
    var block = new float[rate * 2];
    long n = 0;
    for (int s = 0; s < (int)Math.Ceiling(seconds); s++)
    {
        for (int f = 0; f < rate; f++, n++)
        {
            float v = amplitude * (float)Math.Sin(2 * Math.PI * freq * n / rate);
            block[2 * f] = v;
            block[2 * f + 1] = v;
        }
        wav.Write(block);
    }
    Say($"wrote {path}: {freq} Hz at {level} dBFS for {Math.Ceiling(seconds)} s");
    return 0;
}

int Run(List<string> a)
{
    double seconds = Number(a, "--seconds", 10);
    double rebuildAt = Number(a, "--rebuild-at", -1);
    uint period = (uint)Number(a, "--period", 64);
    string? record = Option(a, "--record");
    bool asFloat = a.Remove("--float");
    string? venueName = Option(a, "--venue"), streamName = Option(a, "--stream");
    var noVenue = Options(a, "--no-venue").Select(int.Parse).ToHashSet();
    // --fader <track>=<dB>
    var faders = Options(a, "--fader").Select(f => f.Split('=')).ToDictionary(f => int.Parse(f[0]), f => double.Parse(f[1], CultureInfo.InvariantCulture));
    var devices = AudioDevices.List();
    AudioDevice Find(string fragment, bool input) =>
        devices.FirstOrDefault(d => d.IsInput == input && d.Name.Contains(fragment, StringComparison.OrdinalIgnoreCase))
        ?? throw new ArgumentException($"no {(input ? "input" : "output")} matching \"{fragment}\"");

    var tracks = new List<Track>();
    foreach (var spec in Options(a, "--track"))
    {
        TrackSource source;
        if (spec == "system")
        {
            source = new SystemAudioSource();
        }
        else if (spec.StartsWith("app=", StringComparison.Ordinal))
        {
            source = new AppSource(spec[4..].ToLowerInvariant(), spec[4..]);
        }
        else if (spec.StartsWith("dev=", StringComparison.Ordinal))
        {
            int colon = spec.LastIndexOf(':');
            var device = Find(spec[4..colon], input: true);
            string channel = spec[(colon + 1)..];
            bool stereo = channel.EndsWith('s');
            source = new DeviceSource(device.Id, device.Name, int.Parse(channel.TrimEnd('s'), CultureInfo.InvariantCulture), stereo);
        }
        else
        {
            throw new ArgumentException($"unknown track \"{spec}\"");
        }
        tracks.Add(new Track($"Track {tracks.Count + 1}", source)
        {
            SendToVenue = !noVenue.Contains(tracks.Count + 1), FaderDb = faders.GetValueOrDefault(tracks.Count + 1),
        });
    }

    IMicSystem[] systems = [new DjiMicMini2S()];
    var plan = EnginePlan.Build(tracks.Select(t => t.Source).ToList(), devices, systems,
                                venueName == null ? null : Find(venueName, input: false).Id, streamName == null ? null : Find(streamName, input: false).Id,
                                AudioApps.ProcessFor, (uint)Environment.ProcessId);
    Say($"clock: {(plan.ClockFromInput ? "input " + plan.Inputs[0].Name : "output " + plan.ClockOutput?.Name)}");
    for (int i = 0; i < plan.Inputs.Count; i++) Say($"source {i}: {plan.Inputs[i].Name} ({plan.Inputs[i].SampleRate} Hz)");
    for (int l = 0; l < plan.Loopbacks.Count; l++) Say($"source {plan.Inputs.Count + l}: loopback {plan.Loopbacks[l].Name} pid {plan.Loopbacks[l].ProcessId}{(plan.Loopbacks[l].Exclude ? " excluded" : "")}");
    for (int t = 0; t < plan.Tracks.Count; t++) Say($"track {t + 1}: source {plan.Tracks[t].Input} channel {plan.Tracks[t].Channel}{(plan.Tracks[t].Stereo ? " stereo" : "")}");
    if (plan.Warning != null) Say($"warning: {plan.Warning}");

    using var engine = new NativeEngine();
    var status = engine.Start(plan, period, core =>
    {
        for (int t = 0; t < tracks.Count; t++)
        {
            Native.AudioCoreSetTrackVenueSend(core, t, tracks[t].SendToVenue);
            Native.AudioCoreSetTrackGain(core, t, Decibels.Linear(tracks[t].FaderDb));
        }
    });
    Say($"running at {status.SampleRate} Hz, period {status.PeriodFrames}, venue latency {Ms(status.VenueLatencyMs)}");
    for (int t = 0; t < status.TrackLatencyMs.Count; t++) if (status.TrackLatencyMs[t] is double ms) Say($"track {t + 1} runs {ms:0.0} ms behind");
    foreach (var problem in status.Problems) Say($"problem: {problem}");

    RecordingSession? session = record == null ? null
        : RecordingSession.Start(engine.Core, record, tracks.Select(t => (t.Name, t.Source.IsStereo ? 2 : 1)).ToList(), status.SampleRate,
                                 asFloat ? RecordingFormat.Float32 : RecordingFormat.Pcm24, DateTime.Now);
    if (session != null) Say($"recording to {session.Folder}");

    ulong lastCallbacks = 0;
    var started = DateTime.Now;
    while ((DateTime.Now - started).TotalSeconds < seconds && engine.IsRunning)
    {
        Thread.Sleep(1000);
        if (rebuildAt >= 0 && (DateTime.Now - started).TotalSeconds >= rebuildAt)
        {
            // What a device change or a new buffer size does mid-recording.
            rebuildAt = -1;
            engine.Start(plan, period, core =>
            {
                for (int t = 0; t < tracks.Count; t++) Native.AudioCoreSetTrackVenueSend(core, t, tracks[t].SendToVenue);
            });
            Say("rebuilt the engine");
        }
        var meters = Meters(engine.Core);
        var line = new List<string> { $"{(DateTime.Now - started).TotalSeconds,4:0}s", $"cb {meters.Callbacks - lastCallbacks}" };
        lastCallbacks = meters.Callbacks;
        for (int t = 0; t < tracks.Count; t++) line.Add($"t{t + 1} {Db(meters.Left[t])}");
        line.Add($"stream {Db(meters.Stream)}");
        line.Add($"venue {Db(meters.Venue)}");
        string Stats(string label, AudioCoreAsyncStats s) => $"{label} buf {s.BufferedFrames:0} {s.Correction * 1e6:+0;-0} ppm u{s.Underruns} o{s.Overflows}";
        for (int i = 0; i < plan.Inputs.Count + plan.Loopbacks.Count; i++)
        {
            var s = engine.InputStats(i);
            if (s.Running == 0 && s.BufferedFrames == 0 && s.Underruns == 0) continue;
            line.Add(Stats($"src{i}", s));
        }
        foreach (var (label, index) in new[] { ("venue-rs", 0), ("stream-rs", 1) })
        {
            var s = engine.OutputStats(index);
            if (s.Running != 0 || s.BufferedFrames != 0 || s.Underruns != 0) line.Add(Stats(label, s));
        }
        Say(string.Join(" | ", line));
    }
    if (!engine.IsRunning) Say("engine stopped: a device failed");
    if (session != null) Say($"recording stopped, {session.Stop()} buffers dropped");
    engine.Stop();
    return 0;
}

static string Ms(double? ms) => ms is double v ? $"{v:0.0} ms" : "-";
static string Db(float peak) => peak > 0 ? $"{20 * Math.Log10(peak):0.0}" : "-inf";

static unsafe (ulong Callbacks, float[] Left, float Stream, float Venue) Meters(IntPtr core)
{
    AudioCoreMeters m;
    Native.AudioCoreReadMeters(core, &m);
    var left = new float[Native.MaxTracks];
    for (int i = 0; i < left.Length; i++) left[i] = m.PeakLeft[i];
    return (m.Callbacks, left, m.StreamPeak, m.VenuePeak);
}

int Analyze(List<string> a)
{
    double freq = Number(a, "--freq", 1000);
    int channel = (int)Number(a, "--channel", 0);
    string path = a.FirstOrDefault() ?? throw new ArgumentException("analyze needs a file");
    var bytes = File.ReadAllBytes(path);
    int format = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(20)), channels = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(22));
    int rate = (int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(24)), bits = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(34));
    int dataBytes = (int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(40));
    int frameBytes = channels * bits / 8, frames = dataBytes / frameBytes;
    var x = new double[frames];
    for (int f = 0; f < frames; f++)
    {
        int at = 44 + f * frameBytes + channel * bits / 8;
        x[f] = format == 3 ? BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(at))
             : (bytes[at] | bytes[at + 1] << 8 | (sbyte)bytes[at + 2] << 16) / 8_388_608.0;
    }
    Say($"{Path.GetFileName(path)}: {channels} ch, {rate} Hz, {bits}-bit, {frames / (double)rate:0.00} s");

    // Where the signal is: from the first to the last sample above -50 dBFS, minus 100 ms at each end.
    double threshold = Math.Pow(10, -50 / 20.0);
    int first = Array.FindIndex(x, v => Math.Abs(v) > threshold), last = Array.FindLastIndex(x, v => Math.Abs(v) > threshold);
    if (first < 0) { Say("silent"); return 0; }
    first += rate / 10;
    last -= rate / 10;
    if (last <= first) { Say("too short"); return 0; }
    double sum = 0;
    for (int i = first; i < last; i++) sum += x[i] * x[i];
    double rms = Math.Sqrt(sum / (last - first));
    Say($"signal {first / (double)rate:0.00} s to {last / (double)rate:0.00} s, {20 * Math.Log10(rms):0.0} dBFS RMS ({20 * Math.Log10(rms * Math.Sqrt(2)):0.0} dBFS sine peak)");

    // Frequency from rising zero crossings, interpolated.
    double? firstCrossing = null, lastCrossing = null;
    int crossings = 0;
    for (int i = first; i < last; i++)
    {
        if (x[i - 1] < 0 && x[i] >= 0)
        {
            double t = i - 1 + x[i - 1] / (x[i - 1] - x[i]);
            firstCrossing ??= t;
            lastCrossing = t;
            crossings++;
        }
    }
    if (crossings > 1) Say($"frequency {(crossings - 1) / ((lastCrossing!.Value - firstCrossing!.Value) / rate):0.000} Hz");

    // Dropouts: 5 ms blocks 20 dB below the RMS. Clicks: second differences far beyond what a sine of this
    // frequency and level can produce.
    int block = rate / 200, dropouts = 0;
    for (int b = first; b + block < last; b += block)
    {
        double s = 0;
        for (int i = b; i < b + block; i++) s += x[i] * x[i];
        if (Math.Sqrt(s / block) < rms / 10) dropouts++;
    }
    double bound = rms * Math.Sqrt(2) * Math.Pow(2 * Math.PI * freq / rate, 2);
    int clicks = 0;
    double worst = 0;
    for (int i = first + 1; i < last - 1; i++)
    {
        double d2 = Math.Abs(x[i + 1] - 2 * x[i] + x[i - 1]);
        worst = Math.Max(worst, d2 / bound);
        if (d2 > 4 * bound)
        {
            if (clicks < 8) Say($"  click at {i / (double)rate:0.0000} s ({d2 / bound:0.0}x)");
            clicks++;
        }
    }
    Say($"dropouts {dropouts} (5 ms blocks), clicks {clicks}, worst curvature {worst:0.00}x a clean sine's");
    return 0;
}

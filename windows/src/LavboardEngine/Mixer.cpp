// The engine: one endpoint clocks the shared mixer; every other device runs through the shared
// async resampler, on its own thread.

#include "Engine.h"
#include "Wasapi.h"

#include <avrt.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cwchar>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

using namespace lavboard;

void lbNotifyDeviceChange(); // Devices.cpp

namespace {

constexpr uint32_t kMaxFrames = AC_ASYNC_MAX_FRAMES;
constexpr int kVenueBuffer = 0, kStreamBuffer = 1, kClockBuffer = 2;

/// An AudioBufferList with room for three buffers, laid out like the variable-length C struct.
struct BufferList {
    UInt32 count = 0;
    std::array<AudioBuffer, 3> buffers{};
    AudioBufferList *get() { return reinterpret_cast<AudioBufferList *>(this); }
};

void copyText(wchar_t *dest, size_t capacity, const std::wstring &text) { wcsncpy_s(dest, capacity, text.c_str(), _TRUNCATE); }

/// Raises the calling thread to the multimedia class scheduler's pro audio priority.
class ProAudioThread {
public:
    ProAudioThread() : task_(AvSetMmThreadCharacteristicsW(L"Pro Audio", &index_)) {}
    ~ProAudioThread() {
        if (task_) AvRevertMmThreadCharacteristics(task_);
    }

private:
    DWORD index_ = 0;
    HANDLE task_;
};

/// Source frames to keep buffered between a producer delivering `producerChunk` frames at a time
/// and a consumer taking `consumerChunk` consumer frames at a time, plus 2 ms of scheduling
/// jitter. The same rule the macOS engine uses for devices on their own clock.
uint32_t headroomFrames(double producerRate, uint32_t producerChunk, double consumerRate, uint32_t consumerChunk) {
    double frames = 1.5 * producerChunk + 2.0 * consumerChunk * producerRate / consumerRate + 0.002 * producerRate;
    return static_cast<uint32_t>(frames + 0.999);
}

} // namespace

struct LbEngine {
    struct Input {
        std::unique_ptr<Stream> stream;
        AudioCoreAsyncSource *source = nullptr; // null for the clock input
        std::thread thread;
        double latencyMs = 0;
    };

    struct Output {
        std::unique_ptr<Stream> stream; // null when the output is the clock endpoint, or off
        AudioCoreAsyncSource *source = nullptr;
        std::thread thread;
        std::vector<float> mix; // the mixer's stereo output for this cycle
        bool active = false;    // the mixer writes this output
        bool onClock = false;   // written straight into the clock endpoint's buffer
        double latencyMs = 0;
    };

    explicit LbEngine(AudioCore *c) : core(c), stopEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
    ~LbEngine() {
        stop();
        if (stopEvent) CloseHandle(stopEvent);
    }

    int32_t start(const LbEngineConfig &config, LbEngineInfo &info, std::wstring &error);
    void stop() {
        std::lock_guard lock(lifecycle);
        stopLocked();
    }
    void stopLocked();

    void runMixerFromInput();
    void runMixerFromOutput();
    void runInput(Input *input);
    void runOutput(Output *output);
    void mix(uint32_t frames, const float *clockInput, uint32_t clockChannels, float *clockOutput, uint32_t clockOutputChannels);
    void fail();

    AudioCore *core;
    HANDLE stopEvent;
    std::mutex lifecycle;
    std::atomic<bool> running{false};

    std::vector<Input> inputs;
    std::unique_ptr<Stream> clock; // the endpoint driving the mixer
    bool clockIsInput = false;
    Output venue, stream;
    std::vector<float> silence;
    std::thread mixer;
};

void LbEngine::fail() {
    if (running.exchange(false)) lbNotifyDeviceChange();
}

void LbEngine::mix(uint32_t frames, const float *clockInput, uint32_t clockChannels, float *clockOutput, uint32_t clockOutputChannels) {
    BufferList in, out;
    if (clockInput) {
        in.count = 1;
        in.buffers[0] = {clockChannels, frames * clockChannels * static_cast<UInt32>(sizeof(float)), const_cast<float *>(clockInput)};
    }
    out.count = 3;
    for (auto [output, index] : {std::pair{&venue, kVenueBuffer}, std::pair{&stream, kStreamBuffer}}) {
        if (!output->active) continue;
        if (output->onClock) {
            out.buffers[index] = {clockOutputChannels, frames * clockOutputChannels * static_cast<UInt32>(sizeof(float)), clockOutput};
        } else {
            out.buffers[index] = {2, frames * 2 * static_cast<UInt32>(sizeof(float)), output->mix.data()};
        }
    }
    // A clock output that plays neither mix still gets its frame count (and silence) from here.
    if (clockOutput && !(venue.onClock || stream.onClock)) {
        out.buffers[kClockBuffer] = {clockOutputChannels, frames * clockOutputChannels * static_cast<UInt32>(sizeof(float)), clockOutput};
    }
    AudioCoreIOProc(0, nullptr, in.get(), nullptr, out.get(), nullptr, core);

    for (Output *output : {&venue, &stream}) {
        if (!output->active || output->onClock || !output->source) continue;
        BufferList feed;
        feed.count = 1;
        feed.buffers[0] = {2, frames * 2 * static_cast<UInt32>(sizeof(float)), output->mix.data()};
        AudioCoreAsyncIOProc(0, nullptr, feed.get(), nullptr, nullptr, nullptr, output->source);
    }
}

void LbEngine::runMixerFromInput() {
    ComScope com;
    ProAudioThread priority;
    IAudioCaptureClient *capture = clock->captureClient();
    const uint32_t channels = clock->channels();
    const HANDLE waits[] = {stopEvent, clock->event()};
    while (running) {
        DWORD woke = WaitForMultipleObjects(2, waits, FALSE, 1000);
        if (woke == WAIT_OBJECT_0) break;
        if (woke != WAIT_OBJECT_0 + 1) continue;
        for (;;) {
            UINT32 packet = 0;
            if (FAILED(capture->GetNextPacketSize(&packet))) return fail();
            if (packet == 0) break;
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) return fail();
            const float *samples = (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? silence.data() : reinterpret_cast<const float *>(data);
            for (uint32_t done = 0; done < frames;) {
                uint32_t chunk = std::min(frames - done, kMaxFrames);
                mix(chunk, samples + static_cast<size_t>(done) * channels, channels, nullptr, 0);
                done += chunk;
            }
            capture->ReleaseBuffer(frames);
        }
    }
}

void LbEngine::runMixerFromOutput() {
    ComScope com;
    ProAudioThread priority;
    IAudioRenderClient *render = clock->renderClient();
    IAudioClient *client = clock->client();
    const uint32_t channels = clock->channels();
    const HANDLE waits[] = {stopEvent, clock->event()};
    while (running) {
        DWORD woke = WaitForMultipleObjects(2, waits, FALSE, 1000);
        if (woke == WAIT_OBJECT_0) break;
        if (woke != WAIT_OBJECT_0 + 1) continue;
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) return fail();
        uint32_t frames = std::min(clock->bufferFrames() - padding, kMaxFrames);
        if (frames == 0) continue;
        BYTE *data = nullptr;
        if (FAILED(render->GetBuffer(frames, &data))) return fail();
        mix(frames, nullptr, 0, reinterpret_cast<float *>(data), channels);
        render->ReleaseBuffer(frames, 0);
    }
}

void LbEngine::runInput(Input *input) {
    ComScope com;
    ProAudioThread priority;
    IAudioCaptureClient *capture = input->stream->captureClient();
    const uint32_t channels = input->stream->channels();
    const HANDLE waits[] = {stopEvent, input->stream->event()};
    while (running) {
        DWORD woke = WaitForMultipleObjects(2, waits, FALSE, 1000);
        if (woke == WAIT_OBJECT_0) break;
        if (woke != WAIT_OBJECT_0 + 1) continue;
        for (;;) {
            UINT32 packet = 0;
            if (FAILED(capture->GetNextPacketSize(&packet))) return fail();
            if (packet == 0) break;
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) return fail();
            BufferList list;
            list.count = 1;
            const void *samples = (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? static_cast<const void *>(silence.data()) : data;
            for (uint32_t done = 0; done < frames;) {
                uint32_t chunk = std::min(frames - done, kMaxFrames);
                list.buffers[0] = {channels, chunk * channels * static_cast<UInt32>(sizeof(float)),
                                   const_cast<float *>(static_cast<const float *>(samples) + static_cast<size_t>(done) * channels)};
                AudioCoreAsyncIOProc(0, nullptr, list.get(), nullptr, nullptr, nullptr, input->source);
                done += chunk;
            }
            capture->ReleaseBuffer(frames);
        }
    }
}

void LbEngine::runOutput(Output *output) {
    ComScope com;
    ProAudioThread priority;
    Stream &device = *output->stream;
    IAudioRenderClient *render = device.renderClient();
    IAudioClient *client = device.client();
    const uint32_t channels = device.channels();
    const HANDLE waits[] = {stopEvent, device.event()};
    while (running) {
        DWORD woke = WaitForMultipleObjects(2, waits, FALSE, 1000);
        if (woke == WAIT_OBJECT_0) break;
        if (woke != WAIT_OBJECT_0 + 1) continue;
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) return fail();
        uint32_t frames = std::min(device.bufferFrames() - padding, kMaxFrames);
        if (frames == 0) continue;
        AudioCoreAsyncRender(output->source, frames);
        const float *left = AudioCoreAsyncOutput(output->source, 0);
        const float *right = AudioCoreAsyncOutput(output->source, 1);
        BYTE *data = nullptr;
        if (FAILED(render->GetBuffer(frames, &data))) return fail();
        float *out = reinterpret_cast<float *>(data);
        for (uint32_t f = 0; f < frames; f++) {
            float l = left ? left[f] : 0.0f, r = right ? right[f] : l;
            float *frame = out + static_cast<size_t>(f) * channels;
            if (channels == 1) {
                frame[0] = 0.5f * (l + r);
                continue;
            }
            frame[0] = l;
            frame[1] = r;
            for (uint32_t c = 2; c < channels; c++) frame[c] = 0.0f;
        }
        render->ReleaseBuffer(frames, 0);
    }
}

void LbEngine::stopLocked() {
    running = false;
    SetEvent(stopEvent);
    if (mixer.joinable()) mixer.join();
    for (auto &input : inputs) {
        if (input.thread.joinable()) input.thread.join();
    }
    for (Output *output : {&venue, &stream}) {
        if (output->thread.joinable()) output->thread.join();
    }
    if (clock) clock->stop();
    for (auto &input : inputs) {
        if (input.stream) input.stream->stop();
    }
    for (Output *output : {&venue, &stream}) {
        if (output->stream) output->stream->stop();
    }
    // Every thread has finished, so nothing reads the sources any more.
    AudioCoreSetLayout(core, nullptr, 0, -1, -1);
    AudioCoreSetAsyncSources(core, nullptr, 0);
    for (auto &input : inputs) AudioCoreAsyncDestroy(input.source);
    inputs.clear();
    for (Output *output : {&venue, &stream}) {
        AudioCoreAsyncDestroy(output->source);
        *output = Output{};
    }
    clock.reset();
    ResetEvent(stopEvent);
}

int32_t LbEngine::start(const LbEngineConfig &config, LbEngineInfo &info, std::wstring &error) {
    std::lock_guard lock(lifecycle);
    stopLocked();
    info = {};
    info.venueLatencyMs = -1;
    for (double &latency : info.trackLatencyMs) latency = -1;

    const int inputCount = std::clamp(config.inputCount, 0, LB_MAX_INPUTS);
    clockIsInput = config.clockFromInput && inputCount > 0;
    const wchar_t *clockId = clockIsInput ? config.inputIds[0] : config.clockOutputId;
    if (!clockId) {
        error = L"No device to run the mixer on.";
        return -1;
    }
    clock = std::make_unique<Stream>();
    if (std::wstring why = clock->open(clockId, clockIsInput, config.periodFrames); !why.empty()) {
        error = why;
        clock.reset();
        return -2;
    }
    const double rate = clock->rate();
    const uint32_t period = clock->periodFrames();
    info.sampleRate = static_cast<int32_t>(rate);
    info.periodFrames = static_cast<int32_t>(period);
    silence.assign(static_cast<size_t>(kMaxFrames) * 64, 0.0f);

    // Inputs: the clock's own reaches the mixer directly; the others are resampled.
    const double clockedInputMs = clockIsInput ? (clock->latencyFrames() + period) / rate * 1000.0 : 0.0;
    inputs.resize(inputCount);
    std::vector<AudioCoreAsyncSource *> sources(inputCount, nullptr);
    for (int i = 0; i < inputCount; i++) {
        if (clockIsInput && i == 0) continue;
        auto device = std::make_unique<Stream>();
        if (std::wstring why = device->open(config.inputIds[i], true, 0); !why.empty()) {
            copyText(info.inputErrors[i], LB_PROBLEM_LENGTH, why);
            continue;
        }
        const double deviceRate = device->rate();
        const uint32_t headroom = headroomFrames(deviceRate, device->periodFrames(), rate, period);
        int channels = std::min<int>(static_cast<int>(device->channels()), AC_ASYNC_MAX_CHANNELS);
        AudioCoreAsyncSource *source = AudioCoreAsyncCreate(channels, deviceRate, rate, headroom);
        if (!source) {
            copyText(info.inputErrors[i], LB_PROBLEM_LENGTH, L"runs at a rate the engine can't convert");
            continue;
        }
        inputs[i].latencyMs = (device->latencyFrames() + device->periodFrames() + headroom + AudioCoreAsyncLookahead(source)) / deviceRate * 1000.0;
        inputs[i].stream = std::move(device);
        inputs[i].source = source;
        sources[i] = source;
    }

    // Outputs: written straight into the clock endpoint when it is the clock, else resampled.
    auto openOutput = [&](Output &output, const wchar_t *id, wchar_t *errorText) {
        if (!id) return;
        output.mix.assign(static_cast<size_t>(kMaxFrames) * 2, 0.0f);
        if (!clockIsInput && _wcsicmp(id, clockId) == 0) {
            output.active = output.onClock = true;
            output.latencyMs = clock->latencyFrames() / rate * 1000.0;
            return;
        }
        auto device = std::make_unique<Stream>();
        if (std::wstring why = device->open(id, false, 0); !why.empty()) {
            copyText(errorText, LB_PROBLEM_LENGTH, why);
            return;
        }
        const double deviceRate = device->rate();
        const uint32_t headroom = headroomFrames(rate, period, deviceRate, device->periodFrames());
        output.source = AudioCoreAsyncCreate(2, rate, deviceRate, headroom);
        if (!output.source) {
            copyText(errorText, LB_PROBLEM_LENGTH, L"runs at a rate the engine can't convert");
            return;
        }
        output.latencyMs = (headroom + AudioCoreAsyncLookahead(output.source)) / rate * 1000.0 + device->latencyFrames() / deviceRate * 1000.0;
        output.stream = std::move(device);
        output.active = true;
    };
    openOutput(venue, config.venueId, info.venueError);
    openOutput(stream, config.streamId, info.streamError);
    if (venue.active) info.venueLatencyMs = clockedInputMs + venue.latencyMs;

    // Track layouts: buffer 0 is the clock input; any other input is its async source.
    std::array<AudioCoreTrackLayout, AC_MAX_TRACKS> layouts{};
    const int trackCount = std::clamp(config.trackCount, 0, AC_MAX_TRACKS);
    for (int t = 0; t < trackCount; t++) {
        const LbTrackSpec &spec = config.tracks[t];
        AudioCoreTrackLayout &layout = layouts[t];
        layout = {-1, -1, -1, -1, spec.stereo != 0, -1};
        if (spec.input < 0 || spec.input >= inputCount) continue;
        if (clockIsInput && spec.input == 0) {
            layout.buffer = 0;
            layout.channel = spec.channel;
            if (spec.stereo) layout.bufferRight = 0, layout.channelRight = spec.channel + 1;
        } else if (sources[spec.input]) {
            layout.asyncSource = spec.input;
            layout.channel = spec.channel;
            layout.channelRight = spec.stereo ? spec.channel + 1 : -1;
            info.trackLatencyMs[t] = std::max(0.0, inputs[spec.input].latencyMs - clockedInputMs);
        }
    }
    AudioCoreSetAsyncSources(core, sources.data(), inputCount);
    AudioCoreSetLayout(core, layouts.data(), trackCount, venue.active ? kVenueBuffer : -1, stream.active ? kStreamBuffer : -1);

    // Resampled devices start first, so audio is buffered by the time the mixer runs.
    running = true;
    for (int i = 0; i < inputCount; i++) {
        Input &input = inputs[i];
        if (!input.stream) continue;
        if (FAILED(input.stream->start())) {
            copyText(info.inputErrors[i], LB_PROBLEM_LENGTH, L"couldn't start");
            continue;
        }
        info.inputRunning[i] = 1;
        input.thread = std::thread(&LbEngine::runInput, this, &input);
    }
    if (clockIsInput) info.inputRunning[0] = 1;
    for (auto [output, errorText] : {std::pair{&venue, info.venueError}, std::pair{&stream, info.streamError}}) {
        if (!output->stream) continue;
        if (FAILED(output->stream->start())) {
            copyText(errorText, LB_PROBLEM_LENGTH, L"couldn't start");
            output->active = false;
            continue;
        }
        output->thread = std::thread(&LbEngine::runOutput, this, output);
    }
    if (HRESULT hr = clock->start(); FAILED(hr)) {
        error = L"couldn't start (" + hresultText(hr) + L")";
        stopLocked();
        return -3;
    }
    mixer = std::thread(clockIsInput ? &LbEngine::runMixerFromInput : &LbEngine::runMixerFromOutput, this);
    return 0;
}

extern "C" LbEngine *LbEngineCreate(AudioCore *core) { return core ? new LbEngine(core) : nullptr; }

extern "C" int32_t LbEngineStart(LbEngine *engine, const LbEngineConfig *config, LbEngineInfo *info, wchar_t *error, int32_t errorCapacity) {
    if (!engine || !config || !info) return -1;
    ComScope com;
    std::wstring message;
    int32_t result = engine->start(*config, *info, message);
    if (error && errorCapacity > 0) wcsncpy_s(error, static_cast<size_t>(errorCapacity), message.c_str(), _TRUNCATE);
    return result;
}

extern "C" void LbEngineStop(LbEngine *engine) {
    if (engine) engine->stop();
}

extern "C" void LbEngineDestroy(LbEngine *engine) { delete engine; }

extern "C" int32_t LbEngineIsRunning(LbEngine *engine) { return engine && engine->running ? 1 : 0; }

extern "C" void LbEngineReadInputStats(LbEngine *engine, int32_t input, AudioCoreAsyncStats *out) {
    if (!out) return;
    *out = {};
    if (!engine || input < 0) return;
    std::lock_guard lock(engine->lifecycle);
    if (input < static_cast<int32_t>(engine->inputs.size()) && engine->inputs[input].source) {
        AudioCoreAsyncReadStats(engine->inputs[input].source, out);
    }
}

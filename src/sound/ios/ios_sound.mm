/* This file is part of OpenTTD. Licensed under GPL version 2; see COPYING.md. */
#include "../../stdafx.h"
#include "../sound_driver.hpp"
#include "../../debug.h"
#include "../../mixer.h"
#include "../../os/ios/ios_bridge.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <array>
#include <thread>

namespace {
constexpr uint32_t SAMPLE_RATE = 48000;
constexpr uint32_t RING_FRAMES = 8192;
constexpr uint32_t MIX_FRAMES = 512;
constexpr uint32_t TARGET_FRAMES = 2048;
constexpr uint32_t EVENT_REBUILD = 1;

struct AudioState {
    AudioUnit unit = nullptr; // Control/producer thread only; disposed after stopping callbacks.
    std::array<int16_t, RING_FRAMES * 2> ring{};
    std::atomic<uint64_t> read{0}, written{0};
    std::atomic<uint64_t> rendered_frames{0}, audible_frames{0}, underruns{0};
    std::atomic<bool> stopping{false}, enabled{false}, available{false}, interrupted{false}, resume_allowed{true};
    std::atomic<uint32_t> events{EVENT_REBUILD};
    std::thread worker;
};
static_assert(std::atomic<uint64_t>::is_always_lock_free);

/* Real-time callback: bounded zero/copy operations and lock-free atomics only.
 * Upstream MxMixSamples includes a music mutex, so it runs on our producer instead. */
OSStatus Render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *buffers)
{
    auto &state = *static_cast<AudioState *>(context);
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
        if (buffers->mBuffers[i].mData != nullptr) std::memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
    }
    if (!state.enabled.load(std::memory_order_acquire) || buffers->mNumberBuffers != 1 || buffers->mBuffers[0].mData == nullptr) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    auto &buffer = buffers->mBuffers[0];
    uint64_t read = state.read.load(std::memory_order_relaxed);
    uint64_t written = state.written.load(std::memory_order_acquire);
    uint32_t count = static_cast<uint32_t>(std::min<uint64_t>({written - read, frames, buffer.mDataByteSize / 4}));
    uint32_t offset = static_cast<uint32_t>(read % RING_FRAMES);
    uint32_t first = std::min(count, RING_FRAMES - offset);
    std::memcpy(buffer.mData, state.ring.data() + offset * 2, first * 4);
    if (count > first) std::memcpy(static_cast<int16_t *>(buffer.mData) + first * 2, state.ring.data(), (count - first) * 4);
    state.read.store(read + count, std::memory_order_release);
    state.rendered_frames.fetch_add(count, std::memory_order_relaxed);
    if (count < frames) state.underruns.fetch_add(1, std::memory_order_relaxed);
    if (count == 0) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

void CloseUnit(AudioState &state)
{
    state.enabled.store(false, std::memory_order_release);
    if (state.unit == nullptr) return;
    AudioOutputUnitStop(state.unit);
    AudioUnitUninitialize(state.unit);
    AudioComponentInstanceDispose(state.unit);
    state.unit = nullptr;
    state.available.store(false, std::memory_order_release);
    // Callback is stopped and this producer owns both indices during reset.
    state.read.store(0, std::memory_order_relaxed);
    state.written.store(0, std::memory_order_relaxed);
}

bool OpenUnit(AudioState &state)
{
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryAmbient mode:AVAudioSessionModeDefault options:0 error:&error] ||
            ![session setPreferredSampleRate:SAMPLE_RATE error:&error] ||
            ![session setPreferredIOBufferDuration:double(MIX_FRAMES) / SAMPLE_RATE error:&error] ||
            ![session setActive:YES error:&error]) {
        Debug(driver, 0, "iOS audio session unavailable; silent fallback: {}", error.localizedDescription.UTF8String ?: "unknown error");
        return false;
    }
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr || AudioComponentInstanceNew(component, &state.unit) != noErr) {
        Debug(driver, 0, "iOS RemoteIO component unavailable; silent fallback");
        return false;
    }
    UInt32 disabled = 0;
    UInt32 enabled = 1;
    AudioStreamBasicDescription format{};
    format.mSampleRate = SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = format.mBytesPerFrame = 4;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    AURenderCallbackStruct callback{Render, &state};
    OSStatus status = AudioUnitSetProperty(state.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, sizeof(disabled));
    if (status == noErr) status = AudioUnitSetProperty(state.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, sizeof(enabled));
    if (status == noErr) status = AudioUnitSetProperty(state.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (status == noErr) status = AudioUnitSetProperty(state.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status == noErr) status = AudioUnitInitialize(state.unit);
    if (status == noErr) {
        state.enabled.store(true, std::memory_order_release);
        status = AudioOutputUnitStart(state.unit);
    }
    if (status != noErr) {
        Debug(driver, 0, "iOS RemoteIO setup failed ({}); silent fallback", status);
        CloseUnit(state);
        return false;
    }
    state.available.store(true, std::memory_order_release);
    Debug(driver, 0, "iOS RemoteIO sound effects active: 48000 Hz stereo, output only");
    return true;
}

void RunAudio(const std::shared_ptr<AudioState> &state)
{
    bool previously_active = false;
    bool attempted = false;
    bool logged_samples = false;
    std::array<int16_t, MIX_FRAMES * 2> mixed{};
    while (!state->stopping.load(std::memory_order_acquire)) {
        @autoreleasepool {
            bool active = IOSIsActive() && !state->interrupted.load() && state->resume_allowed.load();
            uint32_t events = state->events.exchange(0);
            if (!active || events != 0) {
                CloseUnit(*state);
                if (previously_active && !active) {
                    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
                    Debug(driver, 1, "iOS sound effects suspended");
                }
                if (!active || events != 0) attempted = false;
            }
            if (active && !attempted) {
                attempted = true;
                if (!OpenUnit(*state)) {
                    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
                } // On failure stay silent until a lifecycle/route event permits another attempt.
            }
            previously_active = active;
            if (active && state->available.load(std::memory_order_acquire)) {
                uint64_t written = state->written.load(std::memory_order_relaxed);
                uint64_t read = state->read.load(std::memory_order_acquire);
                if (written - read < TARGET_FRAMES) {
                    MxMixSamples(mixed.data(), MIX_FRAMES);
                    if (std::ranges::any_of(mixed, [](int16_t sample) { return sample != 0; })) state->audible_frames.fetch_add(MIX_FRAMES);
                    uint32_t offset = static_cast<uint32_t>(written % RING_FRAMES);
                    uint32_t first = std::min(MIX_FRAMES, RING_FRAMES - offset);
                    std::memcpy(state->ring.data() + offset * 2, mixed.data(), first * 4);
                    if (first < MIX_FRAMES) std::memcpy(state->ring.data(), mixed.data() + first * 2, (MIX_FRAMES - first) * 4);
                    state->written.store(written + MIX_FRAMES, std::memory_order_release);
                    if (!logged_samples && state->audible_frames.load() != 0 && state->rendered_frames.load() != 0) {
                        Debug(driver, 0, "iOS audio mixed nonzero engine sound; RemoteIO consumed {} frames", state->rendered_frames.load());
                        logged_samples = true;
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(state->available.load() ? 2 : 50));
    }
    @autoreleasepool {
        CloseUnit(*state);
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
}

class SoundDriver_IOS final : public SoundDriver {
    std::shared_ptr<AudioState> state;
    NSMutableArray *observers = nil;
public:
    ~SoundDriver_IOS() override { this->Stop(); }
    std::string_view GetName() const override { return "ios"; }
    bool HasOutput() const override { return this->state && this->state->available.load(); }
    std::optional<std::string_view> Start(const StringList &) override
    {
        this->state = std::make_shared<AudioState>();
        MxInitialize(SAMPLE_RATE);
        this->observers = [NSMutableArray array];
        std::weak_ptr<AudioState> weak = this->state;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification, AVAudioSessionRouteChangeNotification, AVAudioSessionMediaServicesWereResetNotification]) {
            id observer = [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *notification) {
                auto state = weak.lock();
                if (!state) return;
                if ([notification.name isEqualToString:UIApplicationWillResignActiveNotification]) state->enabled.store(false);
                if ([notification.name isEqualToString:UIApplicationDidBecomeActiveNotification]) state->resume_allowed.store(true);
                if ([notification.name isEqualToString:AVAudioSessionRouteChangeNotification]) {
                    auto reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
                    // Our own category configuration must not trigger an endless rebuild cycle.
                    if (reason == AVAudioSessionRouteChangeReasonCategoryChange) return;
                    // Do not unexpectedly play through the speaker after headphones are removed.
                    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
                        state->resume_allowed.store(false);
                        state->enabled.store(false);
                    } else if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
                        state->resume_allowed.store(true);
                    }
                }
                if ([notification.name isEqualToString:AVAudioSessionMediaServicesWereResetNotification]) {
                    state->interrupted.store(false);
                    state->resume_allowed.store(true);
                }
                state->events.fetch_or(EVENT_REBUILD);
            }];
            [this->observers addObject:observer];
        }
        id interruption = [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
            auto state = weak.lock();
            if (!state) return;
            auto type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            if (type == AVAudioSessionInterruptionTypeBegan) {
                state->interrupted.store(true);
                state->enabled.store(false);
            } else {
                state->interrupted.store(false);
                auto options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
                state->resume_allowed.store((options & AVAudioSessionInterruptionOptionShouldResume) != 0);
            }
            state->events.fetch_or(EVENT_REBUILD);
        }];
        [this->observers addObject:interruption];
        try {
            this->state->worker = std::thread(RunAudio, this->state);
        } catch (const std::exception &error) {
            Debug(driver, 0, "iOS audio worker unavailable; silent fallback: {}", error.what());
            this->Stop();
        }
        return std::nullopt;
    }
    void Stop() override
    {
        if (!this->state) return;
        for (id observer in this->observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
        this->observers = nil;
        this->state->enabled.store(false);
        this->state->stopping.store(true, std::memory_order_release);
        if (this->state->worker.joinable()) this->state->worker.join();
        this->state.reset();
    }
};
class FSoundDriver_IOS final : public DriverFactoryBase {
public:
    FSoundDriver_IOS() : DriverFactoryBase(Driver::DT_SOUND, 10, "ios", "Native iOS RemoteIO sound effects") {}
    std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<SoundDriver_IOS>(); }
};
static FSoundDriver_IOS factory;
}

# Native iOS sound effects

`ios_sound.mm` supplies the upstream mixer with a 48 kHz, signed 16-bit stereo output through Apple's RemoteIO audio unit. Input bus 1 is explicitly disabled; no microphone permission or background-audio entitlement is requested. AVAudioSession uses Ambient, so the hardware silent switch and other applications' audio remain respected. Music stays on the null driver.

The real-time render callback only clears/copies a bounded fixed-capacity single-producer/single-consumer ring and updates lock-free counters. `MxMixSamples` runs on a separate producer because the existing mixer uses a music mutex. No UIKit or simulation code runs in the callback. The producer targets 2,048 buffered frames and handles audio-unit start, stop, destruction and reconstruction.

Lifecycle, interruption, route and media-services-reset notifications only request state changes. The producer stops output when inactive, honors interruption `shouldResume`, rebuilds after route/reset events, and pauses after headphones disappear until reconnection or foreground activation. Initial device/session failures fall back to silence and retry only after a relevant event; they do not prevent game startup. Stop removes observers and joins the producer after disposing the audio unit.

Diagnostics outside the callback report successful RemoteIO initialization and the first nonzero upstream mix after output frames have been consumed. These diagnostics establish software activity, not physical audibility. Simulator/device compilation does not validate hardware interruption, Bluetooth/headphone switching, speaker quality, latency or the silent switch; test those on a provisioned physical iPhone/iPad.

Implementation references (Apple primary documentation checked 2026-09-19):

- [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [RemoteIO audio unit](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_remoteio)
- [Audio unit render callback](https://developer.apple.com/documentation/audiotoolbox/aurendercallback)

The current Xcode iOS SDK headers provide the exact RemoteIO bus, stream-format, session and notification declarations used by the build.

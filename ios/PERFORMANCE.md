# Simulator performance and adapter fault review

## Repeatable, read-only measurement

Find the currently running app PIDs (do not reuse the historical PIDs below), then run:

```sh
ps -axo pid,etime,command | rg '/openttd.app/openttd'
./ios/measure-simulator.py PID [OTHER_PID] --seconds 10 --sample
```

The script accepts only running OpenTTD CoreSimulator processes. It does not install, launch, terminate, change a scene, modify game state or request elevated privileges. Evidence goes into a unique `build/validation/performance-YYYYMMDD-HHMMSS` directory. CPU is the change in process CPU time divided by measured wall time; 100% means one host CPU core. This avoids interpreting the smoothed `ps %cpu` value as a short-window measurement. RSS is recorded separately. Optional stack sampling runs after the counter interval and is coarse diagnostic evidence, not a profiler attribution or frame-time measurement.

## Observed 2026-09-19 22:07 local

Evidence: `build/validation/performance-20260919-220725/` (11 counter observations over approximately 10 seconds, followed by 3-second stack-sampling requests).

| Running app | PID | Interval CPU, one host core | RSS range | Later sample physical footprint |
| --- | --- | --- | --- | --- |
| iPad Pro 11-inch M5 Simulator, native sound build | 89370 | 25.6% | 294.66–294.83 MiB | 105.4M, peak109.0M |
| iPhone 17e Simulator, earlier build | 88263 | 18.2% | 147.61–147.66 MiB | 107.5M, peak139.2M |

The app revisions, scenes and resolutions differ, so this is not an iPad-versus-iPhone benchmark. The scenes were left as the parent was using them; no controlled workload or fixed camera was imposed. RSS and Apple's physical-footprint accounting include/exclude shared pages differently and must not be equated. Stable RSS across ten seconds does not establish absence of leaks. These are debug Simulator processes on macOS26.6.2, not physical-device memory limits, CPU use, thermal behavior, battery use or performance guarantees.

Earlier samples `perf-ipad-sample.txt`/`perf-iphone-sample.txt` captured previous builds. In particular, the old iPad engine was in its inactive sleep path during all sampled stacks; do not confuse it with the active latest process above.

## Concrete source observations

- `src/os/ios/ios_application.mm`: the UIKit rendering callback waits synchronously for each Metal command buffer (`waitUntilCompleted`). This safely prevents reuse of a texture still being read by the GPU, but can stall UIKit if GPU work is delayed. The wait appeared in both sampled main-thread stacks. This is not evidence that GPU work alone caused the measured CPU usage. A later measured optimization could rotate retained textures/command buffers with a bounded in-flight limit; simply deleting the wait would introduce a texture lifetime/data hazard.
- `src/video/ios/ios_v.cpp`: MakeDirty currently does nothing and every Paint publishes the whole framebuffer. `IOSPublishFrame` copies every row under the frame mutex; UIKit uploads the copied image while holding that mutex. Copy/upload work therefore scales with framebuffer area even when few pixels change. Sampled engine stacks included this copy and upstream palette animation. Preserve palette-animation correctness and ownership when evaluating dirty-region or double-buffer changes.
- The visible buffers have roughly14 bytes per logical pixel: engine BGRA4, copied BGRA4, Metal texture4 and upstream palette-animation indices2, excluding alignment, drawable/system copies and world/sprite data. At1210×782 that subtotal is about12.6MiB; it does not explain total process memory. The4096×4096 resolution ceiling permits roughly224MiB of these buffers, so exceptionally large windows deserve a device-memory review before increasing the cap.
- `src/sound/ios/ios_sound.mm`: the audio producer sleeps between checks; it appeared asleep in56 of58 sampled producer stacks. One stack showed upstream mixing. This observation does not prove real-time safety of every dependency or inaudible latency. The RemoteIO callback itself uses bounded copies/zero fill and lock-free counters; UIKit and mixer locks stay outside it.
- Metal-device availability is asserted, while shader/pipeline errors are logged and cause rendering to return. A persistent shader/pipeline failure can leave a black screen without a user-facing diagnostic. No such failure occurred in this sample. A future fault-injection pass should verify a recoverable on-screen error path, command-buffer errors and allocation failures.

## Memory-warning handling

The shell owner agreed to add `didReceiveMemoryWarning` on the UIKit controller that releases only the dispensable copied framebuffer and Metal texture, retaining frame dimensions for input mapping. Existing rendering checks for an empty frame; a later engine publication recreates the presentation cache. The engine framebuffer, simulation, sprite cache and save state must remain untouched. At1210×782 the two presentation caches account for approximately7.2MiB before allocator overhead. The saving is transient while actively publishing; it persists when the engine is background-paused. Compilation and a simulated memory-warning/recovery check remain the shell owner's validation responsibility.

## Next useful measurements

Use Instruments on a provisioned physical device with an optimized build, fixed save/camera and recorded resolution. Compare a paused world, active ordinary gameplay and a large vehicle-heavy world; include foreground/background transitions, resizing, sound, a prolonged session and memory pressure. Record frame-time percentiles and thermal state before changing frame rate, buffering, copies or cache policy. The current evidence supports preserving the simple ownership model while establishing that baseline.

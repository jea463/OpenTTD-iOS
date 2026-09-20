# Native iOS controls

The native view sends semantic touch events to the engine thread. It never reads game windows, construction tools, or simulation state. Touch coordinates use the displayed framebuffer and its aspect-fit rectangle; there is no movable virtual cursor.

- **Buttons, menus, and dialogs:** tap directly. Press and drag still works for scrollbars, movable windows, and toolbar menus. Toolbar menus also stay open for a separate second tap on a menu item. Desktop hover tooltips are disabled so they cannot cover the next touch target.
- **Map without a construction tool:** tap to inspect/select. Drag one finger to move the map with the finger. A six-framebuffer-pixel movement threshold distinguishes a tap from a drag; the initial map click is deferred so panning does not select objects.
- **Map with a construction tool:** tap to place, or drag one finger to use the existing tool. A stationary initial contact is deferred until release; movement beyond the same threshold begins the existing construction drag at its original position.
- **Two fingers:** place both fingers on the map and drag to pan while retaining the selected construction tool. The remaining finger is ignored after one finger lifts until all fingers lift, avoiding accidental placement.
- **Pinch:** spread to zoom in; pinch together to zoom out. Each 30% separation change requests one existing OpenTTD zoom step around the current centroid. Zoom remains subject to the game's normal limits.
- **Long press:** existing right-click behavior outside an active construction touch. Precision construction suppresses it to preserve the pending placement.
- **Text fields:** use the system keyboard. The game view shrinks above the docked keyboard, keeping dialogs visible. The framebuffer scales uniformly toward the 640×480 design minimum while preserving the available view aspect ratio, then scales to fit smaller available areas (maximum texture dimension 4096). Committed text and backspace/return are supported; complex marked-text composition still needs further work.

## Cancellation boundary

When iOS cancels input, the app resizes, or a second finger takes over, the driver clears held input. An unfinished placement drag does not receive a placement mouse-up. Its original placement UI mode is restored only while the same owning tool window still exists; otherwise the upstream abort helper resets placement. No gameplay command is reversed. Some tools execute commands while dragging or on initial placement: adding a second finger after those commands execute cannot undo them. Place two fingers together before moving when panning with a selected tool.

All viewport movement uses existing window scrolling, and zoom uses the existing cursor-centered viewport zoom function. No simulation, construction command, save format, or networking logic is changed.

## Validation status

The first touch build compiled and linked, and runtime testing confirmed one-finger viewport panning, autorail drag construction on iPad (screenshot: `build/validation/ios-touch-rail-built.png`), and loading a desktop-resaved game. Separate toolbar taps were subsequently verified after disabling touch hover tooltips. Phone keyboard resizing, committed software text, backspace/Return and the Show keyboard button were subsequently verified in Simulator. Two-finger pan, pinch and construction cancellation still require physical gesture verification.

On backgrounding, UIKit grants a finite background execution lease and requests a save from the engine owner thread. Unfinished touch sequences are cancelled before saving; old touch events are discarded during inactivity. Completion or lease expiration releases the lease on the main thread. The persistence module owns save verification and atomic promotion; lease expiration never deletes a previous save.

Background/resume runtime verification: an iPad background transition created a verified resume save; terminating and relaunching restored the world and its constructed railway (`build/validation/ios-background-resume.png`).

## iPad pointer and hardware keyboard

A mouse or trackpad uses UIKit indirect-pointer events, independent of the touch gesture state machine. Primary click/drag dispatches normal desktop mouse input immediately; secondary click/drag dispatches right-button input. Hover uses the native system pointer and restores hover tooltips. Mouse wheel and two-finger trackpad scrolling use UIKit scroll events and the existing engine wheel behavior. Touchscreen two-finger gestures remain a separate path. Switching input method or backgrounding clears held input to avoid stuck buttons and keys.

Physical keyboard presses carry USB HID usages and Shift, Control, Option, and Command modifiers to the engine. The adapter supports letter/number shortcuts, Escape, Return, Tab, Backspace/Delete, arrows, Home/End, Page Up/Down, F1–F12, and common keypad/punctuation keys. Held arrows update normal engine directional scrolling; held Tab follows the existing fast-forward behavior. System-reserved keyboard shortcuts remain owned by iPadOS.

While a text field is focused, printable hardware text is delivered only through the native text field, just like software-keyboard committed text. Navigation/control keys and Control/Command shortcuts go through the key adapter. This avoids inserting a character both as a key and as text. Complex IME marked-text composition remains unsupported by the existing committed-text bridge.

Hardware support compiles but has not been tested with a physical iPad keyboard, mouse, or trackpad. Simulator touch injection does not establish indirect-pointer behavior. Relevant UIKit contracts: [scroll-only pan recognition](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask), and the installed SDK UIKey, UIEvent, and UIPointerInteraction headers.

The keyboard resize path now calls upstream `GameSizeChanged()` so the main viewport and open windows relocate to the new framebuffer, instead of repainting a stale viewport in the upper-left corner.

## Phone precision placement

While a construction tool is active, a single finger shows a phone-only pixel loupe above the contact (below it when needed near the top edge). It magnifies a small crop of the engine's copied framebuffer with a crosshair; the original game's highlight remains the placement preview. UIKit reads only copied target coordinates and pixels.

For a conservative set of known single-placement tools—rail/road depots and tunnels, airports, and dock depots/locks/stations/buoys—moving the finger adjusts the preview and releasing commits at the final position. Adding a second finger or cancellation abandons the uncommitted placement. Rail, road, station-area, terraform, and other drag tools retain their upstream behavior, with the loupe showing the current endpoint. Long press is suppressed while construction feedback is active so it cannot unexpectedly cancel precision placement. Physical pointer behavior is unchanged.

The whitelist is necessary because highlight modes such as `HT_RECT` are shared by both single placements and drag tools; it is not a replacement simulation or construction-command implementation. Loupe and release-only behavior still require runtime validation.

## Keyboard and window layout

If an edit field retains focus after its software keyboard is hidden, a native **Show keyboard** button appears. Its 44-point target occupies a separate strip outside the game canvas and disappears when the keyboard is visible. Reopening cycles UIKit first responder without duplicating text input.

On iPadOS26+, the canvas uses the public vertically adapted safe-area layout region to avoid windowing controls and requests the minimal control style. Earlier systems retain their normal safe area. Resizing remains supported; no fullscreen-only restriction is introduced. See Apple's [adaptive UIKit windowing guidance](https://developer.apple.com/videos/play/wwdc2025/282/).

A memory warning discards only the native copied framebuffer, texture, and loupe image. Engine world state and its framebuffer remain intact, and the next published frame recreates the display cache.

Simulator hardware-keyboard checks confirmed F1 pause and station-name typing followed by Return without duplicate characters. Physical keyboard modifiers, mouse/trackpad behavior, and multitouch still need device verification.

Runtime iPadOS27 testing showed that the adapted safe-area guide can reserve no extra height in fullscreen, while rapid game-toolbar taps still trigger system titlebar double-tap window resizing. The iPad canvas therefore reserves an additional 44-point top strip below the adapted safe area, consistently in fullscreen and narrower windows. This keeps game controls out of the observed system gesture region without disabling windowing.

The additional iPad top strip passed the same rapid toolbar/menu tap sequence that previously resized the window. Phone autorail drag also constructed track. The automated drag was too brief to visually establish the loupe during a held touch; that acceptance remains open.

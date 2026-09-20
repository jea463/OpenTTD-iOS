# Moving ordinary OpenTTD saves

The development app exposes its Documents directory through Apple's Files app and Finder file sharing. Saves retain the standard OpenTTD `.sav` format.

In Files, open **Browse → On My iPhone / On My iPad → OpenTTD iOS Dev → save**. Copy a desktop save here from another Files location, then reopen OpenTTD's Load Game dialog to refresh the list. Saves requiring missing NewGRFs still require those same compatible assets; this does not convert them.

To export, make a manual save in OpenTTD, background the game, then use Files to copy or share that `.sav`. Files provides the system share sheet, AirDrop and transfers to configured providers such as iCloud Drive. This port does not implement a separate cloud sync service or automatic conflict resolution. Duplicate rather than move the only copy of a save that you want to keep on the device.

The entire development Documents directory is visible, including config, ordinary autosaves and the two recovery snapshots. Prefer exchanging named manual saves. Do not replace recovery files while the app is running; background saving may replace them. Files-based changes appear when the game's file browser is reopened. Direct Open In handling and an in-game native document picker are not implemented yet.

The keys follow Apple's documented [file-sharing setting](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled) and [local file-provider behavior](https://developer-mdn.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html). Device/provider-specific transfer tests remain part of release validation.

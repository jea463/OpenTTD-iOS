/* This file is part of OpenTTD. Licensed under GPL version 2; see COPYING.md. */
#pragma once
#include <optional>
#include <string>

/** Initialize paths and select a checked resume save. Call on the engine owner before openttd_main. */
std::optional<std::string> IOSPrepareResume(const char *documents_path, const char *executable_path);
/** Synchronously preserve config and, in a stable normal game, save an atomic native resume. Engine thread only. */
bool IOSSaveResume();
/** Confirm a resume loaded successfully after a normal game tick. Engine thread only. */
void IOSResumeLoadCompleted();

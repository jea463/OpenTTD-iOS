/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software
 * Foundation, version 2. OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General
 * Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_bridge.h Thread-safe native UI and engine boundary. */

#pragma once
#include <cstdint>
#include <string>
#include <utility>
enum class IOSEventType
{
	PointerMove,
	LeftDown,
	LeftUp,
	RightDown,
	RightUp,
	Scroll,
	Text,
	Key,
	Resize,
	TouchBegin,
	TouchMove,
	TouchEnd,
	TouchCancel,
	MultiBegin,
	MultiMove,
	MultiEnd,
	Zoom,
	HardwarePointerMove,
	HardwarePointerButtons,
	HardwarePointerLeave,
	HardwareScroll,
	HardwareKeyDown,
	HardwareKeyUp,
	HardwareModifiers,
	HardwareReset
};
enum IOSModifier : uint32_t
{
	IOSShift = 1,
	IOSControl = 2,
	IOSAlternate = 4,
	IOSCommand = 8
};
// Hardware keys use USB HID usages; pointer button bits: 1=primary, 2=secondary.
// HardwareScroll dx/dy are UIKit scroll deltas in points.
// Key values use ASCII control codes: 8 = backspace, 13 = return.
// Resize uses x/y for logical dimensions; pointer positions are framebuffer pixels.
struct IOSEvent
{
	IOSEventType type = IOSEventType::PointerMove;
	int x = 0;
	int y = 0;
	int value = 0;
	std::string text;
	int dx = 0;
	int dy = 0;
	uint32_t modifiers = 0;
	IOSEvent() = default;
	IOSEvent(IOSEventType type, int x = 0, int y = 0, int value = 0, std::string text = {}) : type(type), x(x), y(y), value(value), text(std::move(text))
	{
	}
};
bool IOSPollEvent(IOSEvent &event);
void IOSPublishFrame(const uint32_t *pixels, int width, int height, int pitchPixels);
void IOSGetSurfaceSize(int &width, int &height);
bool IOSIsActive();
void IOSRunEngine(const char *resourcePath, const char *documentsPath);
void IOSRequestTextInput(bool enabled);

// Background save requests are consumed only by the engine owner thread.
uint64_t IOSConsumeBackgroundSaveRequest();
void IOSCompleteBackgroundSave(uint64_t ticket, bool saved);

// Engine-owned construction feedback; native UI only reads this copied state.
void IOSSetConstructionTouch(bool active, int x = 0, int y = 0);

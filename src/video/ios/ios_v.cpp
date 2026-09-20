/* This file is part of OpenTTD. Licensed under GPL version 2; see COPYING.md. */
#include "../../stdafx.h"
#include "../video_driver.hpp"
#include "../../blitter/factory.hpp"
#include "../../gfx_func.h"
#include "../../window_func.h"
#include "../../os/ios/ios_bridge.h"
#include "../../os/ios/ios_persistence.h"
#include "../../openttd.h"
#include "../../window_gui.h"
#include "../../viewport_func.h"
#include "../../tilehighlight_func.h"
#include "../../tilehighlight_type.h"
#include "../../settings_type.h"
#include "../../transport_type.h"
#include "../../widgets/rail_widget.h"
#include "../../widgets/road_widget.h"
#include "../../widgets/dock_widget.h"
#include "../../widgets/airport_widget.h"

class VideoDriver_IOS final : public VideoDriver
{
	std::vector<uint32_t> pixels;
	Palette palette{};
	enum class TouchMode
	{
		None,
		GUI,
		PendingViewport,
		Pan,
		ToolDrag
	};
	TouchMode touch_mode = TouchMode::None;
	Point touch_start{}, touch_last{};
	WindowClass touch_window_class = WC_INVALID;
	WindowNumber touch_window_number = 0;
	WindowClass tool_class = WC_INVALID;
	WindowNumber tool_number = 0;
	HighLightStyle tool_mode = HT_NONE;
	SpecialMouseMode tool_mouse_mode = WSM_NONE;
	WidgetID release_only_widget = INVALID_WIDGET;

	int hardware_scroll_remainder = 0;
	int saved_hover_delay = -1;
	bool hardware_pointer_mode = false;
	void ApplyModifiers(uint32_t modifiers)
	{
		bool previous = _ctrl_pressed;
		_ctrl_pressed = (modifiers & IOSControl) != 0;
		_shift_pressed = (modifiers & IOSShift) != 0;
		if (previous != _ctrl_pressed)
			HandleCtrlChanged();
	}
	void ResetHardwareInput()
	{
		this->ApplyModifiers(0);
		_dirkeys = 0;
		this->fast_forward_key_pressed = false;
		this->hardware_scroll_remainder = 0;
	}
	static uint HardwareKeyCode(const IOSEvent &event)
	{
		// USB HID keyboard page usages, identical to UIKey.keyCode.
		int hid = event.value;
		if (hid >= 4 && hid <= 29)
		{
			if (event.text.size() == 1)
			{
				char c = event.text[0];
				if (c >= 'a' && c <= 'z')
					return c - 'a' + 'A';
				if (c >= 'A' && c <= 'Z')
					return c;
			}
			return 'A' + hid - 4;
		}
		if (hid >= 30 && hid <= 38)
			return '1' + hid - 30;
		if (hid >= 58 && hid <= 69)
			return WKC_F1 + hid - 58;
		if (hid >= 89 && hid <= 97)
			return '1' + hid - 89;
		switch (hid)
		{
		case 39:
		case 98:
			return '0';
		case 40:
			return WKC_RETURN;
		case 41:
			return WKC_ESC;
		case 42:
			return WKC_BACKSPACE;
		case 43:
			return WKC_TAB;
		case 44:
			return WKC_SPACE;
		case 45:
			return WKC_MINUS;
		case 46:
			return WKC_EQUALS;
		case 47:
			return WKC_L_BRACKET;
		case 48:
			return WKC_R_BRACKET;
		case 49:
			return WKC_BACKSLASH;
		case 51:
			return WKC_SEMICOLON;
		case 52:
			return WKC_SINGLEQUOTE;
		case 53:
			return WKC_BACKQUOTE;
		case 54:
			return WKC_COMMA;
		case 55:
			return WKC_PERIOD;
		case 56:
			return WKC_SLASH;
		case 72:
			return WKC_PAUSE;
		case 73:
			return WKC_INSERT;
		case 74:
			return WKC_HOME;
		case 75:
			return WKC_PAGEUP;
		case 76:
			return WKC_DELETE;
		case 77:
			return WKC_END;
		case 78:
			return WKC_PAGEDOWN;
		case 79:
			return WKC_RIGHT;
		case 80:
			return WKC_LEFT;
		case 81:
			return WKC_DOWN;
		case 82:
			return WKC_UP;
		case 84:
			return WKC_NUM_DIV;
		case 85:
			return WKC_NUM_MUL;
		case 86:
			return WKC_NUM_MINUS;
		case 87:
			return WKC_NUM_PLUS;
		case 88:
			return WKC_NUM_ENTER;
		case 99:
			return WKC_NUM_DECIMAL;
		default:
			return WKC_NONE;
		}
	}
	void HardwareKey(const IOSEvent &event, bool down)
	{
		this->ApplyModifiers(event.modifiers);
		uint8_t direction = event.value == 80 ? 1 : event.value == 82 ? 2 : event.value == 79 ? 4 : event.value == 81 ? 8 : 0;
		if (down)
			_dirkeys |= direction;
		else
			_dirkeys &= ~direction;
		if (event.value == 43)
			this->fast_forward_key_pressed = down && !(event.modifiers & IOSAlternate);
		if (!down)
			return;
		uint code = HardwareKeyCode(event);
		if (code == WKC_NONE)
			return;
		if (event.modifiers & IOSShift)
			code |= WKC_SHIFT;
		if (event.modifiers & IOSControl)
			code |= WKC_CTRL;
		if (event.modifiers & IOSAlternate)
			code |= WKC_ALT;
		if (event.modifiers & IOSCommand)
			code |= WKC_META;
		HandleKeypress(code, 0);
	}
	void HardwarePointer(const IOSEvent &event)
	{
		if (!this->hardware_pointer_mode)
		{
			this->CancelTouch();
			this->hardware_pointer_mode = true;
			if (this->saved_hover_delay >= 0)
				_settings_client.gui.hover_delay_ms = this->saved_hover_delay;
		}
		this->ApplyModifiers(event.modifiers);
		_cursor.in_window = event.type != IOSEventType::HardwarePointerLeave;
		_cursor.UpdateCursorPosition(event.x, event.y);
		if (event.type == IOSEventType::HardwarePointerButtons)
		{
			bool left = (event.value & 1) != 0, right = (event.value & 2) != 0;
			if (left && !_left_button_down)
			{
				Window *w = FindWindowFromPt(event.x, event.y);
				this->touch_mode = TouchMode::GUI;
				if (w != nullptr && IsPtInWindowViewport(w, event.x, event.y) != nullptr && _thd.place_mode != HT_NONE)
				{
					this->touch_mode = TouchMode::ToolDrag;
					this->tool_mode = _thd.place_mode;
					this->tool_mouse_mode = _special_mouse_mode;
					this->tool_class = _thd.window_class;
					this->tool_number = _thd.window_number;
				}
			}
			_left_button_down = left;
			if (!left)
				_left_button_clicked = false;
			if (right && !_right_button_down)
				_right_button_clicked = true;
			_right_button_down = right;
		}
		if (event.type == IOSEventType::HardwareScroll)
		{
			// UIKit scroll translations follow the content; engine wheel signs
			// follow the established SDL convention (positive = zoom out).
			this->hardware_scroll_remainder -= event.dy;
			_cursor.wheel += this->hardware_scroll_remainder / 20;
			this->hardware_scroll_remainder %= 20;
			_cursor.v_wheel -= event.dy;
			_cursor.h_wheel -= event.dx;
			_cursor.wheel_moved = true;
		}
		HandleMouseEvents();
		if (event.type == IOSEventType::HardwarePointerButtons && !_left_button_down)
			this->touch_mode = TouchMode::None;
	}

	static WidgetID ReleaseOnlyPlacementWidget()
	{
		// Platform adapter whitelist: HT_RECT alone is insufficient because
		// autoroad, stations and single-placement depots share that highlight.
		// Keep all unlisted tools on their existing upstream drag semantics.
		Window *owner = _thd.GetCallbackWnd();
		if (owner == nullptr || owner->window_class != WC_BUILD_TOOLBAR)
			return INVALID_WIDGET;
		auto lowered = [owner](WidgetID id) { return owner->widget_lookup.contains(id) && owner->IsWidgetLowered(id); };
		switch (owner->window_number)
		{
		case TRANSPORT_RAIL:
			if (lowered(WID_RAT_BUILD_DEPOT))
				return WID_RAT_BUILD_DEPOT;
			if (lowered(WID_RAT_BUILD_TUNNEL))
				return WID_RAT_BUILD_TUNNEL;
			break;
		case TRANSPORT_ROAD:
			if (lowered(WID_ROT_DEPOT))
				return WID_ROT_DEPOT;
			if (lowered(WID_ROT_BUILD_TUNNEL))
				return WID_ROT_BUILD_TUNNEL;
			break;
		case TRANSPORT_WATER:
			for (WidgetID id : {WID_DT_DEPOT, WID_DT_LOCK, WID_DT_STATION, WID_DT_BUOY})
				if (lowered(id))
					return id;
			break;
		case TRANSPORT_AIR:
			if (lowered(WID_AT_AIRPORT))
				return WID_AT_AIRPORT;
			break;
		}
		return INVALID_WIDGET;
	}
	bool SamePlacementTool() const
	{
		if (_thd.window_class != this->tool_class || _thd.window_number != this->tool_number || _thd.place_mode != this->tool_mode)
			return false;
		return this->release_only_widget == INVALID_WIDGET || ReleaseOnlyPlacementWidget() == this->release_only_widget;
	}
	void PreviewConstruction(const IOSEvent &event)
	{
		_cursor.UpdateCursorPosition(event.x, event.y);
		HandleMouseEvents();
		Window *w = FindWindowFromPt(event.x, event.y);
		bool visible = w != nullptr && w == this->TouchWindow() && IsPtInWindowViewport(w, event.x, event.y) != nullptr;
		IOSSetConstructionTouch(visible, event.x, event.y);
	}

	Window *TouchWindow() const
	{
		Window *w = FindWindowById(this->touch_window_class, this->touch_window_number);
		return w != nullptr && w->viewport != nullptr ? w : nullptr;
	}
	void MouseDown(int x, int y)
	{
		_cursor.UpdateCursorPosition(x, y);
		_left_button_down = true;
		HandleMouseEvents();
	}
	void CancelTouch()
	{
		IOSSetConstructionTouch(false);
		// Never release an unfinished placement through OnPlaceMouseUp.
		if (this->touch_mode == TouchMode::ToolDrag && (_special_mouse_mode == WSM_SIZING || _special_mouse_mode == WSM_DRAGGING))
		{
			if (_thd.window_class == this->tool_class && _thd.window_number == this->tool_number && _thd.GetCallbackWnd() != nullptr)
			{
				_special_mouse_mode = this->tool_mouse_mode;
				_thd.place_mode = this->tool_mode;
				SetTileSelectSize(1, 1);
			}
			else
			{
				ResetObjectToPlace();
			}
		}
		else if (_special_mouse_mode == WSM_DRAGDROP)
		{
			ResetObjectToPlace();
		}
		_left_button_down = _left_button_clicked = false;
		_right_button_down = _right_button_clicked = false;
		this->touch_mode = TouchMode::None;
	}
	void BeginTouch(const IOSEvent &event)
	{
		// Deferred config loading can run after MainLoop starts. Apply the native
		// click policy at the input boundary before any toolbar creates its menu.
		_settings_client.gui.toolbar_dropdown_autoselect = false;
		this->hardware_pointer_mode = false;
		if (this->saved_hover_delay < 0)
			this->saved_hover_delay = _settings_client.gui.hover_delay_ms;
		// A touch pointer stays stationary after release. Desktop hover tooltips
		// would otherwise cover the next menu item and win its hit test.
		_settings_client.gui.hover_delay_ms = 0;
		CloseWindowByClass(WC_TOOLTIPS);
		this->CancelTouch();
		this->touch_start = this->touch_last = {event.x, event.y};
		Window *w = FindWindowFromPt(event.x, event.y);
		if (w != nullptr && IsPtInWindowViewport(w, event.x, event.y) != nullptr)
		{
			this->touch_window_class = w->window_class;
			this->touch_window_number = w->window_number;
			this->tool_mode = _thd.place_mode;
			this->tool_mouse_mode = _special_mouse_mode;
			this->tool_class = _thd.window_class;
			this->tool_number = _thd.window_number;
			this->touch_mode = TouchMode::PendingViewport;
			this->release_only_widget = ReleaseOnlyPlacementWidget();
			if (this->tool_mode != HT_NONE)
				this->PreviewConstruction(event);
		}
		else
		{
			this->touch_mode = TouchMode::GUI;
			this->MouseDown(event.x, event.y);
		}
	}
	void MoveTouch(const IOSEvent &event)
	{
		if (this->touch_mode == TouchMode::PendingViewport)
		{
			if (this->tool_mode != HT_NONE)
			{
				if (!this->SamePlacementTool())
				{
					this->CancelTouch();
					return;
				}
				this->PreviewConstruction(event);
				if (this->release_only_widget != INVALID_WIDGET)
				{
					this->touch_last = {event.x, event.y};
					return;
				}
			}
			int dx = event.x - this->touch_start.x, dy = event.y - this->touch_start.y;
			if (dx * dx + dy * dy < 36)
				return;
			if (this->tool_mode == HT_NONE)
				this->touch_mode = TouchMode::Pan;
			else
			{
				if (!this->SamePlacementTool())
				{
					this->CancelTouch();
					return;
				}
				this->touch_mode = TouchMode::ToolDrag;
				this->MouseDown(this->touch_start.x, this->touch_start.y);
			}
		}
		if (this->touch_mode == TouchMode::Pan)
		{
			Window *w = this->TouchWindow();
			if (w != nullptr && !w->flags.Test(WindowFlag::DisableVpScroll))
				w->OnScroll({this->touch_last.x - event.x, this->touch_last.y - event.y});
		}
		else if (this->touch_mode == TouchMode::GUI || this->touch_mode == TouchMode::ToolDrag)
		{
			_cursor.UpdateCursorPosition(event.x, event.y);
			HandleMouseEvents();
		}
		this->touch_last = {event.x, event.y};
		if (this->touch_mode == TouchMode::ToolDrag)
			IOSSetConstructionTouch(true, event.x, event.y);
	}
	void EndTouch(const IOSEvent &event)
	{
		IOSSetConstructionTouch(false);
		if (this->touch_mode == TouchMode::PendingViewport)
		{
			Window *w = FindWindowFromPt(event.x, event.y);
			if (w == nullptr || w != this->TouchWindow() || IsPtInWindowViewport(w, event.x, event.y) == nullptr ||
				(this->tool_mode != HT_NONE && !this->SamePlacementTool()))
			{
				this->CancelTouch();
				return;
			}
			this->MouseDown(event.x, event.y);
		}
		if (this->touch_mode != TouchMode::Pan && this->touch_mode != TouchMode::None)
		{
			_cursor.UpdateCursorPosition(event.x, event.y);
			_left_button_down = _left_button_clicked = false;
			HandleMouseEvents();
		}
		this->touch_mode = TouchMode::None;
	}

	void DrainInactiveInput()
	{
		this->CancelTouch();
		this->ResetHardwareInput();
		IOSEvent event;
		// Preserve text already typed, but discard stale touch sequences so
		// backgrounding cannot finish construction or replay it on resume.
		while (IOSPollEvent(event))
		{
			if (event.type == IOSEventType::Text)
				HandleTextInput(event.text);
			else if (event.type == IOSEventType::Key)
				HandleKeypress(event.value == 8 ? WKC_BACKSPACE : event.value == 13 ? WKC_RETURN : event.value, 0);
			else if (event.type == IOSEventType::Resize)
				this->ChangeResolution(event.x, event.y);
		}
	}

  public:
	std::string_view GetName() const override
	{
		return "ios";
	}
	std::optional<std::string_view> Start(const StringList &) override
	{
		this->is_game_threaded = false;
		int width, height;
		IOSGetSurfaceSize(width, height);
		ChangeResolution(width, height);
		CopyPalette(this->palette, true);
		return std::nullopt;
	}
	void Stop() override
	{
		this->pixels.clear();
		_screen.dst_ptr = nullptr;
	}
	void MakeDirty(int, int, int, int) override
	{
	}
	bool ToggleFullscreen(bool) override
	{
		return true;
	}
	bool UseSystemCursor() override
	{
		return true;
	}
	bool ChangeResolution(int width, int height) override
	{
		// Preserve the available view aspect when satisfying OpenTTD's 640x480
		// design minimum. Independent clamping wastes horizontal phone space.
		width = std::max(width, 1);
		height = std::max(height, 1);
		double scale = std::max({1.0, 640.0 / width, 480.0 / height});
		scale = std::min(scale, 4096.0 / std::max(width, height));
		width = static_cast<int>(std::ceil(width * scale));
		height = static_cast<int>(std::ceil(height * scale));
		this->pixels.assign(static_cast<size_t>(width) * height, 0xFF000000);
		_screen.width = _screen.pitch = width;
		_screen.height = height;
		_screen.dst_ptr = this->pixels.data();
		_cur_resolution = {static_cast<uint>(width), static_cast<uint>(height)};
		BlitterFactory::GetCurrentBlitter()->PostResize();
		GameSizeChanged();
		return true;
	}
	bool AfterBlitterChange() override
	{
		return ChangeResolution(_screen.width, _screen.height);
	}
	void EditBoxGainedFocus() override
	{
		IOSRequestTextInput(true);
	}
	void EditBoxLostFocus() override
	{
		IOSRequestTextInput(false);
	}
	void MainLoop() override
	{
		bool was_active = false;
		while (!_exit_game)
		{
			if (uint64_t ticket = IOSConsumeBackgroundSaveRequest(); ticket != 0)
			{
				this->DrainInactiveInput();
				IOSCompleteBackgroundSave(ticket, IOSSaveResume());
			}
			if (!IOSIsActive())
			{
				this->DrainInactiveInput();
				was_active = false;
				std::this_thread::sleep_for(std::chrono::milliseconds(50));
				continue;
			}
			if (!was_active)
			{
				this->next_game_tick = this->next_draw_tick = std::chrono::steady_clock::now();
				was_active = true;
			}
			this->Tick();
			IOSResumeLoadCompleted();
			this->SleepTillNextTick();
		}
	}

  protected:
	void Paint() override
	{
		IOSPublishFrame(this->pixels.data(), _screen.width, _screen.height, _screen.pitch);
	}
	void CheckPaletteAnim() override
	{
		CopyPalette(this->palette, false);
		if (this->palette.count_dirty != 0)
		{
			BlitterFactory::GetCurrentBlitter()->PaletteAnimate(this->palette);
			this->palette.count_dirty = 0;
		}
	}
	bool PollEvent() override
	{
		IOSEvent event;
		if (!IOSPollEvent(event))
			return false;
		switch (event.type)
		{
		case IOSEventType::HardwareKeyDown:
			this->HardwareKey(event, true);
			break;
		case IOSEventType::HardwareKeyUp:
			this->HardwareKey(event, false);
			break;
		case IOSEventType::HardwareModifiers:
			this->ApplyModifiers(event.modifiers);
			break;
		case IOSEventType::HardwareReset:
			this->CancelTouch();
			this->ResetHardwareInput();
			break;
		case IOSEventType::HardwarePointerMove:
		case IOSEventType::HardwarePointerButtons:
		case IOSEventType::HardwarePointerLeave:
		case IOSEventType::HardwareScroll:
			this->HardwarePointer(event);
			break;
		case IOSEventType::TouchBegin:
			this->BeginTouch(event);
			break;
		case IOSEventType::TouchMove:
			this->MoveTouch(event);
			break;
		case IOSEventType::TouchEnd:
			this->EndTouch(event);
			break;
		case IOSEventType::TouchCancel:
			this->CancelTouch();
			break;
		case IOSEventType::MultiBegin:
		{
			this->CancelTouch();
			Window *w = FindWindowFromPt(event.x, event.y);
			this->touch_window_class = WC_INVALID;
			if (w != nullptr && IsPtInWindowViewport(w, event.x, event.y) != nullptr)
			{
				this->touch_window_class = w->window_class;
				this->touch_window_number = w->window_number;
			}
			break;
		}
		case IOSEventType::MultiMove:
		{
			Window *w = this->TouchWindow();
			if (w != nullptr && !w->flags.Test(WindowFlag::DisableVpScroll))
				w->OnScroll({event.dx, event.dy});
			break;
		}
		case IOSEventType::Zoom:
		{
			Window *w = this->TouchWindow();
			if (w != nullptr && IsPtInWindowViewport(w, event.x, event.y) != nullptr)
			{
				_cursor.UpdateCursorPosition(event.x, event.y);
				ZoomInOrOutToCursorWindow(event.value > 0, w);
			}
			break;
		}
		case IOSEventType::MultiEnd:
			this->touch_window_class = WC_INVALID;
			break;
		case IOSEventType::Resize:
			this->CancelTouch();
			this->ChangeResolution(event.x, event.y);
			break;
		case IOSEventType::Text:
			HandleTextInput(event.text);
			break;
		case IOSEventType::Key:
			HandleKeypress(event.value == 8 ? WKC_BACKSPACE : event.value == 13 ? WKC_RETURN : event.value, 0);
			break;
		case IOSEventType::Scroll:
			_cursor.wheel += event.value;
			HandleMouseEvents();
			break;
		default:
			_cursor.UpdateCursorPosition(event.x, event.y);
			switch (event.type)
			{
			case IOSEventType::LeftDown:
				_left_button_down = true;
				break;
			case IOSEventType::LeftUp:
				_left_button_down = _left_button_clicked = false;
				break;
			case IOSEventType::RightDown:
				_right_button_down = _right_button_clicked = true;
				break;
			case IOSEventType::RightUp:
				_right_button_down = false;
				break;
			default:
				break;
			}
			HandleMouseEvents();
			break;
		}
		return true;
	}
};
class FVideoDriver_IOS final : public DriverFactoryBase
{
  public:
	FVideoDriver_IOS() : DriverFactoryBase(Driver::DT_VIDEO, 10, "ios", "Native UIKit / Metal iOS video")
	{
	}
	std::unique_ptr<Driver> CreateInstance() const override
	{
		return std::make_unique<VideoDriver_IOS>();
	}
};
static FVideoDriver_IOS ios_video_factory;

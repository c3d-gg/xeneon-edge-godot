#include "touch_interceptor.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/input.hpp>
#include <godot_cpp/classes/input_event_screen_drag.hpp>
#include <godot_cpp/classes/input_event_screen_touch.hpp>
#include <godot_cpp/core/class_db.hpp>

// windows.h after the godot headers: its macros clash with some godot-cpp names.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>

using namespace godot;

namespace {

constexpr UINT_PTR SUBCLASS_ID = 0x70C4;

LRESULT CALLBACK touch_subclass_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR ref) {
	switch (msg) {
		case WM_POINTERDOWN:
		case WM_POINTERUPDATE:
		case WM_POINTERUP: {
			TouchInterceptor *self = reinterpret_cast<TouchInterceptor *>(ref);
			// Returning without DefSubclassProc means Windows' default handler never
			// sees the touch, so it never makes the fake mouse click or moves the cursor.
			if (self->handle_pointer_message(hwnd, msg, wparam)) {
				return 0;
			}
		} break;
		case WM_NCDESTROY:
			RemoveWindowSubclass(hwnd, touch_subclass_proc, id);
			break;
	}
	return DefSubclassProc(hwnd, msg, wparam, lparam);
}

} // namespace

void TouchInterceptor::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &TouchInterceptor::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &TouchInterceptor::is_enabled);
	ClassDB::bind_method(D_METHOD("get_handled_count"), &TouchInterceptor::get_handled_count);
	ClassDB::bind_method(D_METHOD("get_status"), &TouchInterceptor::get_status);
}

bool TouchInterceptor::set_enabled(bool p_enabled) {
	if (p_enabled == enabled) {
		return true;
	}

	if (p_enabled) {
		HWND h = reinterpret_cast<HWND>(DisplayServer::get_singleton()->window_get_native_handle(DisplayServer::WINDOW_HANDLE, DisplayServer::MAIN_WINDOW_ID));
		if (!h) {
			status = "no window handle";
			return false;
		}
		// Windows sends legacy WM_TOUCH instead of pointer messages to windows
		// registered for it, and WM_TOUCH can't suppress the fake click.
		unregistered_wm_touch = IsTouchWindow(h, nullptr) && UnregisterTouchWindow(h);
		if (!SetWindowSubclass(h, touch_subclass_proc, SUBCLASS_ID, reinterpret_cast<DWORD_PTR>(this))) {
			status = "SetWindowSubclass failed";
			return false;
		}
		hwnd = h;
		enabled = true;
		status = unregistered_wm_touch ? "on (took touch over from WM_TOUCH)" : "on";
	} else {
		HWND h = static_cast<HWND>(hwnd);
		RemoveWindowSubclass(h, touch_subclass_proc, SUBCLASS_ID);
		if (unregistered_wm_touch) {
			RegisterTouchWindow(h, 0);
			unregistered_wm_touch = false;
		}
		for (Slot &s : slots) {
			s.used = false;
		}
		hwnd = nullptr;
		enabled = false;
		status = "off";
	}
	return true;
}

void TouchInterceptor::_exit_tree() {
	set_enabled(false);
}

int TouchInterceptor::find_slot(uint32_t p_pointer_id) const {
	for (int i = 0; i < MAX_TOUCHES; i++) {
		if (slots[i].used && slots[i].pointer_id == p_pointer_id) {
			return i;
		}
	}
	return -1;
}

int TouchInterceptor::claim_slot(uint32_t p_pointer_id) {
	for (int i = 0; i < MAX_TOUCHES; i++) {
		if (!slots[i].used) {
			slots[i].used = true;
			slots[i].pointer_id = p_pointer_id;
			return i;
		}
	}
	return -1;
}

bool TouchInterceptor::handle_pointer_message(void *p_hwnd, uint32_t p_msg, uint64_t p_wparam) {
	const UINT32 pointer_id = GET_POINTERID_WPARAM(p_wparam);
	POINTER_INPUT_TYPE type = PT_POINTER;
	if (!GetPointerType(pointer_id, &type) || type != PT_TOUCH) {
		return false; // mouse and pen keep their normal handling
	}
	POINTER_INFO info = {};
	if (!GetPointerInfo(pointer_id, &info)) {
		return false;
	}

	POINT pt = info.ptPixelLocation;
	ScreenToClient(static_cast<HWND>(p_hwnd), &pt);
	const Vector2 pos(pt.x, pt.y);

	if (p_msg == WM_POINTERDOWN) {
		const int index = claim_slot(pointer_id);
		if (index < 0) {
			return true; // more fingers than we track; still swallow it
		}
		slots[index].last_pos = pos;
		Ref<InputEventScreenTouch> ev;
		ev.instantiate();
		ev->set_window_id(DisplayServer::MAIN_WINDOW_ID);
		ev->set_index(index);
		ev->set_position(pos);
		ev->set_pressed(true);
		Input::get_singleton()->parse_input_event(ev);
	} else if (p_msg == WM_POINTERUPDATE) {
		const int index = find_slot(pointer_id);
		if (index < 0 || slots[index].last_pos == pos) {
			return true;
		}
		Ref<InputEventScreenDrag> ev;
		ev.instantiate();
		ev->set_window_id(DisplayServer::MAIN_WINDOW_ID);
		ev->set_index(index);
		ev->set_position(pos);
		ev->set_relative(pos - slots[index].last_pos);
		ev->set_screen_relative(pos - slots[index].last_pos);
		slots[index].last_pos = pos;
		Input::get_singleton()->parse_input_event(ev);
	} else { // WM_POINTERUP
		const int index = find_slot(pointer_id);
		if (index < 0) {
			return true;
		}
		slots[index].used = false;
		Ref<InputEventScreenTouch> ev;
		ev.instantiate();
		ev->set_window_id(DisplayServer::MAIN_WINDOW_ID);
		ev->set_index(index);
		ev->set_position(pos);
		ev->set_pressed(false);
		ev->set_canceled((info.pointerFlags & POINTER_FLAG_CANCELED) != 0);
		Input::get_singleton()->parse_input_event(ev);
	}

	handled_count++;
	return true;
}

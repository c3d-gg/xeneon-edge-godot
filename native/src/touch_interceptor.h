#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// Takes over Windows touch input for the main window so Windows never turns
// taps into mouse clicks (which is what moves the system cursor).
// Touches are re-emitted as InputEventScreenTouch / InputEventScreenDrag.
class TouchInterceptor : public Node {
	GDCLASS(TouchInterceptor, Node)

public:
	static constexpr int MAX_TOUCHES = 10;

	bool set_enabled(bool p_enabled);
	bool is_enabled() const { return enabled; }
	int64_t get_handled_count() const { return handled_count; }
	String get_status() const { return status; }

	// Called from the window subclass procedure. Returns true if the message was consumed.
	bool handle_pointer_message(void *p_hwnd, uint32_t p_msg, uint64_t p_wparam);

	void _exit_tree() override;

protected:
	static void _bind_methods();

private:
	struct Slot {
		bool used = false;
		uint32_t pointer_id = 0;
		Vector2 last_pos;
	};

	bool enabled = false;
	void *hwnd = nullptr;
	bool unregistered_wm_touch = false;
	int64_t handled_count = 0;
	String status = "off";
	Slot slots[MAX_TOUCHES];

	int find_slot(uint32_t p_pointer_id) const;
	int claim_slot(uint32_t p_pointer_id);
};

} // namespace godot

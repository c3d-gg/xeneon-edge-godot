extends Control

## Touch focus test for the Xeneon Edge.
## Answers two questions about tapping a window on a secondary touchscreen:
##   1. Does the tap steal focus from whatever app/game is in front?
##   2. Does the tap move the system mouse cursor (and can we put it back)?

const EDGE_SIZE := Vector2i(2560, 720)
const TOUCH_GUARD_SEC := 0.8  # ignore cursor movement this long after a touch ends
const CURSOR_CHECK_DELAY_SEC := 0.2
const TAP_RADIUS_PX := 40.0  # cursor this close to the tap point was put there by the touch
const STEAL_WINDOW_SEC := 0.6  # focus change this close to a tap counts as caused by it
const LOG_MAX := 9
const ON_COLOR := Color("2e7d4f")
const OFF_COLOR := Color("8a3b3b")
const NEUTRAL_COLOR := Color("3a4250")
const PAD_COLORS := [
	Color("3d5a80"), Color("5c4d7d"), Color("7d4d6a"), Color("7d5a3d"),
	Color("3d7d6a"), Color("4d6a7d"), Color("6a7d3d"), Color("7d3d4d"),
]

var focus_guard := true
var cursor_restore := false
var warp_is_screen_space := false

var touches := 0
var promoted_clicks := 0
var mouse_clicks := 0
var cursor_jumps := 0
var focus_steals := 0

var has_focus := false
var last_touch_time := -10.0
var last_release_time := -10.0
var last_focus_in_time := -10.0
var last_counted_steal := -10.0
var active_touches := {}
var mouse_history: Array[Dictionary] = []
var gesture_pre_pos := Vector2i.ZERO
var gesture_checked := true
var log_lines := PackedStringArray()

var native: Node  # TouchInterceptor from the GDExtension, null if it isn't built

var status_label: Label
var log_label: Label
var native_pad: ColorRect
var focus_pad: ColorRect
var restore_pad: ColorRect
var clear_pad: ColorRect
var quit_pad: ColorRect
var tap_pads: Array[ColorRect] = []


func _ready() -> void:
	_build_ui()
	_place_on_edge()
	_apply_focus_guard()
	_apply_cursor_restore()
	if ClassDB.class_exists("TouchInterceptor"):
		native = ClassDB.instantiate("TouchInterceptor")
		add_child(native)
		native.set_enabled(true)
		_log("Native touch: %s." % native.get_status())
	else:
		_log("Native touch extension not found (build it in native/).")
	_apply_native()
	_log("Ready. Start a game, then tap the coloured pads.")
	# Layout settles after one frame; report a pad's screen position for scripted tests.
	await get_tree().process_frame
	var r := tap_pads[0].get_global_rect()
	var origin := DisplayServer.window_get_position()
	print("PAD1_SCREEN_CENTER %d %d" % [origin.x + int(r.get_center().x), origin.y + int(r.get_center().y)])
	r = restore_pad.get_global_rect()
	print("RESTORE_SCREEN_CENTER %d %d" % [origin.x + int(r.get_center().x), origin.y + int(r.get_center().y)])
	r = focus_pad.get_global_rect()
	print("FOCUS_SCREEN_CENTER %d %d" % [origin.x + int(r.get_center().x), origin.y + int(r.get_center().y)])
	r = native_pad.get_global_rect()
	print("NATIVE_SCREEN_CENTER %d %d" % [origin.x + int(r.get_center().x), origin.y + int(r.get_center().y)])


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# --- Window placement -------------------------------------------------------

func _place_on_edge() -> void:
	var win := get_window()
	for i in DisplayServer.get_screen_count():
		var s := DisplayServer.screen_get_size(i)
		if s == EDGE_SIZE or s.x >= s.y * 3:
			win.position = DisplayServer.screen_get_position(i)
			win.size = s
			_log("Placed on screen %d (%dx%d)." % [i, s.x, s.y])
			return
	_log("No Edge-shaped screen found, staying on screen %d." % win.current_screen)


# --- Toggles ----------------------------------------------------------------

func _apply_focus_guard() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, focus_guard, get_window().get_window_id())
	_set_pad_text(focus_pad, "Focus guard\n%s" % ("ON" if focus_guard else "OFF"))
	focus_pad.color = ON_COLOR if focus_guard else OFF_COLOR


func _apply_native() -> void:
	if native == null:
		_set_pad_text(native_pad, "Native touch\nnot built")
		native_pad.color = NEUTRAL_COLOR
		return
	var on: bool = native.is_enabled()
	_set_pad_text(native_pad, "Native touch\n%s" % ("ON" if on else "OFF"))
	native_pad.color = ON_COLOR if on else OFF_COLOR


func _apply_cursor_restore() -> void:
	_set_pad_text(restore_pad, "Cursor restore\n%s" % ("ON" if cursor_restore else "OFF"))
	restore_pad.color = ON_COLOR if cursor_restore else OFF_COLOR


# --- Per-frame tracking -----------------------------------------------------

func _process(_delta: float) -> void:
	var now := _now()
	var pos := DisplayServer.mouse_get_position()
	var touching := not active_touches.is_empty() or now - last_release_time < TOUCH_GUARD_SEC
	if not touching and (mouse_history.is_empty() or mouse_history[-1]["pos"] != pos):
		mouse_history.append({"t": now, "pos": pos})
		if mouse_history.size() > 60:
			mouse_history.pop_front()

	status_label.text = "\n".join([
		"Native touch: %s" % ("not built" if native == null else "%s, %d messages handled" % [native.get_status(), native.get_handled_count()]),
		"This app has focus: %s" % ("YES" if has_focus else "no"),
		"Mouse cursor: %d, %d" % [pos.x, pos.y],
		"Touches: %d" % touches,
		"Cursor jumps after a touch: %d" % cursor_jumps,
		"Focus steals after a touch: %d" % focus_steals,
		"Mouse clicks made from touches: %d" % promoted_clicks,
		"Real mouse clicks: %d" % mouse_clicks,
	])


## Last cursor position from before the touch, skipping samples that may
## already include a touch-caused jump.
func _pre_touch_pos(touch_time: float) -> Vector2i:
	for i in range(mouse_history.size() - 1, -1, -1):
		if mouse_history[i]["t"] <= touch_time - 0.12:
			return mouse_history[i]["pos"]
	if not mouse_history.is_empty():
		return mouse_history[0]["pos"]
	return DisplayServer.mouse_get_position()


# --- Input ------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var since := _now() - last_touch_time
		if since < 0.5:
			promoted_clicks += 1
			_log("Mouse click arrived %d ms after a touch (Windows made a click from the tap)." % int(since * 1000))
		else:
			mouse_clicks += 1
			_activate_at(event.position)


func _on_touch(e: InputEventScreenTouch) -> void:
	var now := _now()
	if e.pressed:
		var starts_gesture := active_touches.is_empty()
		active_touches[e.index] = true
		touches += 1
		last_touch_time = now
		if starts_gesture:
			gesture_pre_pos = _pre_touch_pos(now)
			gesture_checked = false
		_activate_at(e.position)
		_maybe_count_steal()
	else:
		active_touches.erase(e.index)
		last_release_time = now
		if active_touches.is_empty():
			# Windows moves the cursor when it turns the tap into a mouse click,
			# which lands ~100 ms after the finger lifts, so check after that.
			var tap_screen := DisplayServer.window_get_position() + Vector2i(e.position)
			get_tree().create_timer(CURSOR_CHECK_DELAY_SEC).timeout.connect(_after_gesture.bind(tap_screen, gesture_pre_pos))


func _after_gesture(tap_screen: Vector2i, pre_pos: Vector2i) -> void:
	_check_cursor(tap_screen)
	if cursor_restore:
		await _restore_cursor(pre_pos, tap_screen, true)
		# Catch any late cursor move from Windows.
		await get_tree().create_timer(0.25).timeout
		_restore_cursor(pre_pos, tap_screen, false)


func _activate_at(pos: Vector2) -> void:
	if _hit(native_pad, pos):
		if native != null:
			# This tap's release will arrive through the other input path with a
			# different index, so forget in-flight touches or one stays stuck down.
			active_touches.clear()
			last_release_time = _now()
			gesture_checked = true
			native.set_enabled(not native.is_enabled())
			_apply_native()
			_log("Native touch: %s." % native.get_status())
	elif _hit(focus_pad, pos):
		focus_guard = not focus_guard
		_apply_focus_guard()
		_log("Focus guard turned %s." % ("ON" if focus_guard else "OFF"))
	elif _hit(restore_pad, pos):
		cursor_restore = not cursor_restore
		_apply_cursor_restore()
		_log("Cursor restore turned %s." % ("ON" if cursor_restore else "OFF"))
	elif _hit(clear_pad, pos):
		touches = 0
		promoted_clicks = 0
		mouse_clicks = 0
		cursor_jumps = 0
		focus_steals = 0
		log_lines.clear()
		_log("Counters cleared.")
	elif _hit(quit_pad, pos):
		get_tree().quit()
	else:
		for i in tap_pads.size():
			if _hit(tap_pads[i], pos):
				_flash(tap_pads[i])
				_log("Tap %d pressed." % (i + 1))
				return


func _hit(c: Control, pos: Vector2) -> bool:
	return c.get_global_rect().has_point(pos)


# --- Cursor checks ----------------------------------------------------------

func _check_cursor(tap_screen: Vector2i) -> void:
	if gesture_checked:
		return
	gesture_checked = true
	var now_pos := DisplayServer.mouse_get_position()
	if Vector2(now_pos).distance_to(Vector2(gesture_pre_pos)) > 2.0:
		cursor_jumps += 1
		_log("Cursor JUMPED from %s to %s (tap at %s)." % [gesture_pre_pos, now_pos, tap_screen])
	else:
		_log("Cursor stayed at %s." % gesture_pre_pos)


func _restore_cursor(target: Vector2i, tap_screen: Vector2i, first_try: bool) -> void:
	var before := DisplayServer.mouse_get_position()
	if before == target:
		if first_try:
			_log("Cursor already where it was; nothing to restore.")
		return
	# Only undo a touch-caused jump. If the cursor is somewhere else, the real
	# mouse moved it, and yanking it back would fight the player.
	if Vector2(before).distance_to(Vector2(tap_screen)) > TAP_RADIUS_PX:
		if first_try:
			_log("Real mouse moved since the tap; leaving the cursor alone.")
		return
	_warp_to(target)
	await get_tree().process_frame
	var got := DisplayServer.mouse_get_position()
	if got != target and first_try:
		# warp_mouse's coordinate space wasn't what we assumed; try the other one.
		warp_is_screen_space = not warp_is_screen_space
		_warp_to(target)
		await get_tree().process_frame
		got = DisplayServer.mouse_get_position()
	if got == target:
		_log("Cursor %s to %s." % ["restored" if first_try else "moved again by Windows, re-restored", target])
	else:
		_log("Cursor restore FAILED (wanted %s, got %s)." % [target, got])


func _warp_to(target: Vector2i) -> void:
	if warp_is_screen_space:
		DisplayServer.warp_mouse(target)
	else:
		DisplayServer.warp_mouse(target - DisplayServer.window_get_position())


# --- Focus checks -----------------------------------------------------------

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			has_focus = true
			last_focus_in_time = _now()
			_log("This app GAINED focus.")
			_maybe_count_steal()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			has_focus = false
			_log("This app lost focus.")


func _maybe_count_steal() -> void:
	if absf(last_focus_in_time - last_touch_time) < STEAL_WINDOW_SEC and last_counted_steal != last_focus_in_time:
		last_counted_steal = last_focus_in_time
		focus_steals += 1
		_log("FOCUS STOLEN by the tap (a fullscreen game would lose focus).")


# --- UI ---------------------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("161a20")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)

	var info := VBoxContainer.new()
	info.custom_minimum_size.x = 900
	row.add_child(info)
	info.add_child(_label("Touch focus test", 34))
	status_label = _label("", 24)
	info.add_child(status_label)
	log_label = _label("", 18)
	log_label.modulate = Color(0.75, 0.8, 0.85)
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.clip_text = true
	info.add_child(log_label)

	var controls := VBoxContainer.new()
	controls.custom_minimum_size.x = 380
	controls.add_theme_constant_override("separation", 12)
	row.add_child(controls)
	native_pad = _pad("", NEUTRAL_COLOR)
	focus_pad = _pad("", NEUTRAL_COLOR)
	restore_pad = _pad("", NEUTRAL_COLOR)
	clear_pad = _pad("Clear counters", NEUTRAL_COLOR)
	quit_pad = _pad("Quit", Color("4a2a2a"))
	for p in [native_pad, focus_pad, restore_pad, clear_pad, quit_pad]:
		controls.add_child(p)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	row.add_child(grid)
	for i in 8:
		var p := _pad("Tap %d" % (i + 1), PAD_COLORS[i])
		grid.add_child(p)
		tap_pads.append(p)


func _pad(text: String, color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var l := _label(text, 28)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(l)
	return r


func _set_pad_text(pad: ColorRect, text: String) -> void:
	(pad.get_child(0) as Label).text = text


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	return l


func _flash(pad: ColorRect) -> void:
	pad.modulate = Color(1.8, 1.8, 1.8)
	create_tween().tween_property(pad, "modulate", Color.WHITE, 0.25)


func _log(msg: String) -> void:
	var line := "%s  %s" % [Time.get_time_string_from_system(), msg]
	print(line)
	log_lines.append(line)
	while log_lines.size() > LOG_MAX:
		log_lines.remove_at(0)
	if log_label:
		log_label.text = "\n".join(log_lines)

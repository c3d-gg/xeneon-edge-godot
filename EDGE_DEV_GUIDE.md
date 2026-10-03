# Developing for the Xeneon Edge

How to build touch apps for the Corsair Xeneon Edge that sit beside a running game without
getting in its way. Everything here was tested with the test app in this repo on Windows 11
in October 2026, unless it is marked as untested.

The goal is an app on the Edge that you can tap while a game is in front, **without the game
losing focus and without the mouse cursor moving**. Both can be done.

## The hardware and screen layout

Example from the test machine (three monitors, with the Edge on the far left):

| Windows display | Size | Windows position | Godot position |
|---|---|---|---|
| DISPLAY5, **the Edge** | 2560×720 | X=-5120, Y=0 | (0, 0), screen index 2 |
| DISPLAY1 | 2560×1440 | X=-2560, Y=0 | (2560, 0) |
| DISPLAY2, primary | 2560×1440 | X=0, Y=0 | (5120, 0) |

Godot shifts screen coordinates so the top-left corner of the whole desktop is (0, 0). That's
why the Edge, which is the leftmost screen, is at the origin in Godot even though Windows puts
it at -5120. Don't hard-code either one. Find the Edge by its shape, as `_place_on_edge()` in
`main.gd` does: a screen of exactly 2560×720, or one at least 3 times wider than it is tall.

## Toolchain

- **Godot 4.7.2**. The Steam build lives at `C:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe`,
  which is also the path `run.bat` uses; change it if yours is somewhere else.
- **Renderer:** GL Compatibility. It's plenty for a UI panel, and it's light on a GPU that's
  also running a game.
- **Native extension** (only needed if you use the native touch path; see below):
  - godot-cpp `10.0.0-stable`, a git submodule in `native/godot-cpp`
    (`git submodule update --init` if you cloned without `--recurse-submodules`)
  - Python 3.14 + SCons 4.11.1: `python -m SCons` in `native/`
  - MSVC 14.44, from the Visual Studio 2022 Build Tools
  - Only the **debug** DLL has been built. Build the release one with
    `python -m SCons target=template_release` before exporting anything.
  - `native/build_profile.json` limits the godot-cpp bindings to the classes the extension
    uses, to speed up builds. Add a class to it if new native code needs one.

Useful commands (run from the project folder):

```sh
# check a script for errors without running it
godot --headless --path . -s res://main.gd --check-only

# run the app and keep its log
godot --path . > run.log 2>&1
```

`run.bat` launches the app without a console window.

## Project settings an Edge app needs

From `project.godot`:

```ini
[display]
window/size/viewport_width=2560
window/size/viewport_height=720
window/size/borderless=true
window/size/always_on_top=true
window/size/no_focus=true            ; the focus guard; see below

[input_devices]
pointing/emulate_touch_from_mouse=false
pointing/emulate_mouse_from_touch=false
```

## Touch input: handle it yourself

Because `emulate_mouse_from_touch` is off, **taps don't drive Godot's GUI**. A `Button` won't
respond to a finger. The test app sets every Control to `mouse_filter = IGNORE`, catches
`InputEventScreenTouch` / `InputEventScreenDrag` in `_input()`, and checks which control was
hit with `control.get_global_rect().has_point(event.position)`. Copy `_activate_at()` and
`_hit()` from `main.gd` as a starting point.

Mouse clicks still come through as `InputEventMouseButton`. Windows may also make a mouse
click out of a tap, roughly 20–80 ms after the touch. `main.gd` treats a click that arrives
less than 0.5 s after a touch as one of these and ignores it, so a single tap isn't handled
twice.

## Two ways to stay out of the game's way

### 1. Focus guard: `WINDOW_FLAG_NO_FOCUS` (simple, try this first)

This is one window flag (`window/size/no_focus=true`, or
`DisplayServer.window_set_flag(WINDOW_FLAG_NO_FOCUS, true, id)`). Tapping the window then
never activates it, so the game keeps focus.

### 2. Native touch interceptor: `native/` GDExtension

`TouchInterceptor` takes over the window's message handling (`SetWindowSubclass`) and
swallows `WM_POINTERDOWN/UPDATE/UP` for touch before Windows' default handling sees them.
Because of that, **Windows never turns the tap into a mouse click**. It sends the touches back
to Godot as `InputEventScreenTouch` / `InputEventScreenDrag`, with indexes 0–9. Mouse and pen
are handled normally.

- It has to unregister the window from legacy `WM_TOUCH`; otherwise Windows sends `WM_TOUCH`
  instead of pointer messages, and that can't stop the fake click. The status message
  "took touch over from WM_TOUCH" means this happened. Turning it off registers the window
  again.
- Using it from a script:
  ```gdscript
  if ClassDB.class_exists("TouchInterceptor"):
      native = ClassDB.instantiate("TouchInterceptor")
      add_child(native)
      native.set_enabled(true)
  ```

### What the tests showed

| Native touch | Focus guard | Windows makes a click | Cursor jumps | Game loses focus |
|---|---|---|---|---|
| ON | ON | no | no | no |
| ON | OFF | no | no | no (1 tap) |
| OFF | ON | yes | no | no (3 taps) |
| OFF | OFF | yes | **yes** | **yes** |

**Recommendation:** turn on the focus guard. Add the native interceptor if the app must not
receive Windows' fake clicks at all, or if the guard alone ever turns out not to be enough;
it was only tested with a few taps. Using both is the setup that was tested most.

## Gotchas found the hard way

- **Switching the native interceptor during a tap leaves a touch stuck down.** The
  finger-down arrives through one input path and the finger-up through the other, which
  numbers touches differently. Godot's own `WM_TOUCH` path doesn't use 0–9. Clear any touch
  state you track whenever you switch it, as `_activate_at()` in `main.gd` does. Better
  still, don't switch it at runtime in a real app.
- **Turning the focus guard OFF activates the window itself.** A focus change right after
  that call isn't a tap stealing focus.
- **Cursor restore (`warp_mouse` back to where the cursor was before the tap) is untested.**
  It never ran against a real jump. It also isn't sure whether `warp_mouse` takes window or
  screen coordinates, so `main.gd` tries one and falls back to the other. With either
  protection on, the cursor doesn't jump anyway.
- Windows moves the cursor ~100 ms after the finger lifts, when it makes the mouse click, so
  any cursor check has to wait (`CURSOR_CHECK_DELAY_SEC = 0.2`).

## How the testing works

Launch the app with its output saved to a log file, tap the Edge with a game running on the
main monitor, then read the log. Every event in `main.gd` goes
through `_log()`, which prints it. At startup the app also prints the screen-space centres of
its pads (`PAD1_SCREEN_CENTER` etc.) for automated taps later.

## Starting a new Edge app

1. Copy `project.godot`, `touch_interceptor.gdextension`, `bin/` and (if you'll need to
   rebuild it) `native/` into the new project.
2. Take from `main.gd`: `_place_on_edge()`, the touch handling in `_input()` / `_on_touch()`
   with `_hit()`, and the setup code that creates the `TouchInterceptor`. Leave out the
   counters, cursor checks and test pads.
3. Build the UI for 2560×720. Make pads big enough for a finger; the test app's pads are
   ~280 px or more and work well.
4. Before shipping: build the release DLL, create an export preset and check the exported
   build finds the extension.

## Ideas

- Game companion panel: big buttons that send hotkeys or macros to the game.
- Live stats strip: FPS, GPU temperature and frame times, plus audio and volume controls.
- Map or reference board you can scroll and zoom by touch without alt-tabbing.
- Stream control: scene switching, chat, alerts.

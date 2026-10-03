# xeneon-edge-godot

Godot 4 test app and developer notes for building touch apps on the **Corsair Xeneon Edge**
(the 2560×720 touchscreen) that you can tap **while a game is running without the game losing
focus or the mouse cursor jumping**.

It works. By default, tapping a window on a secondary touchscreen activates it, which takes
focus away from a fullscreen game, and Windows turns the tap into a mouse click that moves the
cursor. This repo shows two fixes and measures both:

- **Focus guard:** Godot's `WINDOW_FLAG_NO_FOCUS`, a single window flag.
- **Native touch interceptor:** a small GDExtension that handles touch before Windows' default
  handling sees it, so Windows never makes a mouse click from the tap.

| Native touch | Focus guard | Windows makes a click | Cursor jumps | Game loses focus |
|---|---|---|---|---|
| ON | ON | no | no | no |
| ON | OFF | no | no | no |
| OFF | ON | yes | no | no |
| OFF | OFF | yes | **yes** | **yes** |

These are results from a small number of taps on one machine. See the guide for the details.

## Running it

Requires Windows and Godot 4.7+.

```sh
git clone --recurse-submodules https://github.com/c3d-gg/xeneon-edge-godot
godot --path xeneon-edge-godot
```

The very first time Godot opens the project, it may crash while closing. This is a
Godot/godot-cpp bug: any extension class triggers it, not just this one. It only happens once.
See the guide's gotchas.

The app finds the Edge by its shape and fills that screen. Start a game on your main monitor,
then tap the pads. The left side shows counters (cursor jumps, focus steals, mouse clicks
Windows made from taps) and an event log. The buttons on the right turn native touch, the
focus guard and cursor restore on and off.

A prebuilt debug DLL of the extension is in `bin/`, so you don't need a compiler to try it.
To rebuild it, you need Python, SCons and MSVC:

```sh
cd native
python -m SCons                          # debug
python -m SCons target=template_release  # release, needed for exports
```

## Building your own Edge app

Read **[EDGE_DEV_GUIDE.md](EDGE_DEV_GUIDE.md)**. It covers the screen coordinates, the project
settings, handling touch input yourself (Godot's GUI buttons won't respond to a finger), both
fixes, the gotchas, and a checklist for starting a new app.

## License

MIT. godot-cpp (in `native/godot-cpp`, included as a submodule) is MIT-licensed by the Godot
Engine contributors.

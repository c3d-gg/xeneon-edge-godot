# Xeneon Edge touch test

A Godot 4.7 test app for building touch apps on the Corsair Xeneon Edge that don't steal focus
or move the cursor while a game runs. The full platform guide, including test results and
gotchas, is imported below; keep it up to date when you learn something new about the Edge.

@EDGE_DEV_GUIDE.md

## Working here

- After editing `.gd` files, check them with `--check-only` (see the guide).
- Touch tests need the user's finger: launch the app with stdout saved to a log in the
  scratchpad, ask the user to run specific steps, then read the log. Check that each step
  actually shows up in the log before calling it verified.
- `native/` changes need a rebuild with `python -m SCons` in `native/`, and the app must be
  closed first or the DLL is locked.

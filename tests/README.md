Development helpers, not needed to run the app.

`tour_test.gd` — headless smoke test: plays the guided tour to the end,
checks that the interior voyage wraps around without errors and verifies
that ray picking hits the expected structures.

`capture.gd` — drives every mode and writes screenshots to `tests/out/`
(used to produce `docs/screenshots`).

Both are autoloads. To use one, add to `project.godot`:

```ini
[autoload]

QaTest="*res://tests/tour_test.gd"
```

then run `godot --headless --path .` (test) or `godot --path .` (capture), and
remove the autoload line afterwards.

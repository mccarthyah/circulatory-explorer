Development helpers, not needed to run the app.

`tour_test.gd` — headless smoke test: plays the guided tour to the end,
checks that the interior voyage wraps around without errors, verifies that ray
picking hits the expected structures, and reloads all three detail levels
(printing triangle counts and an arch-of-aorta pick for each).

`capture.gd` — drives every mode and writes screenshots to `tests/out/`
(used to produce `docs/screenshots`); it shoots the nine documentation stills at
the *Balanced* preset and then the same heart viewpoint at Performance and High
for the detail comparison.

Both are autoloads. To use one, add to `project.godot`:

```ini
[autoload]

QaTest="*res://tests/tour_test.gd"
```

then run `godot --headless --path .` (test) or `godot --path .` (capture), and
remove the autoload line afterwards.

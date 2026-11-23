# Testing and benchmarking

## Automated smoke tests

Install Godot **4.7.2**, then run from the repository root:

```sh
GODOT=/path/to/godot ./tests/run.sh
```

The runner imports the assets and checks Performance startup even with a saved
higher setting, quality and resolution changes, individual hide/show across
mesh reloads, mode transitions, ghost visibility, mesh availability, interior
wrapping, controller input, mouse capture/release, the H shortcut, persistent per-view hidden-structure saves, box-selection/undo and synthetic ray-picking cases. It exits nonzero on a failed check and uses an isolated settings file (via `EXPLORER_SETTINGS_PATH` and `EXPLORER_VISIBILITY_PATH`) so it
does not modify your saved settings. GitHub Actions runs the same suite with
the official 4.7.2 Linux binary and verifies its SHA-256.
CI also runs `render_smoke.gd` under Xvfb with Mesa software OpenGL to exercise
the default Compatibility renderer and capture frames in each mode. This smoke test
does not establish visual correctness or measure physical-GPU performance.

`tour_test.gd` is an older manual, print-only smoke helper. `capture.gd` is a
manual screenshot helper. Both can be run as autoloads; see their comments.

## Graphics benchmark

First import the project in the editor (or run
`godot --headless --editor --path . --import`). On a Linux target machine with a
real graphical display, run:

```sh
GODOT=/path/to/godot ./tests/benchmark.sh performance --resolution 1280x720
GODOT=/path/to/godot BENCH_SCALE=0.5 ./tests/benchmark.sh performance --resolution 1280x720
GODOT=/path/to/godot ./tests/benchmark.sh performance --resolution 1280x720 --rendering-method forward_plus
```

On Windows, use PowerShell from the project directory instead of the shell
wrapper (replace the executable path with your Godot binary):

```powershell
$old = $env:EXPLORER_SETTINGS_PATH
$env:EXPLORER_SETTINGS_PATH = Join-Path $env:TEMP ("explorer-bench-" + [guid]::NewGuid() + ".cfg")
try {
    & "C:\path\to\Godot_v4.7.2-stable_win64.exe" --path . --resolution 1280x720 --script res://tests/benchmark.gd -- performance
} finally {
    Remove-Item -ErrorAction SilentlyContinue $env:EXPLORER_SETTINGS_PATH
    $env:EXPLORER_SETTINGS_PATH = $old
}
```

To compare Forward Plus on Windows, add `--rendering-method forward_plus`
before `--script`. The same isolated settings file mechanism is used on both
platforms.

The benchmark selects `performance`, `balanced`, or `high` after startup.
`BENCH_SCALE` may be 0 (preset), 0.5, 0.65, 0.75, 0.9 or 1.0.
`BENCH_WARMUP` and `BENCH_DURATION` override the sample durations in seconds
(the defaults are recommended for comparisons). The benchmark uses isolated
settings, disables VSync, warms each fixed viewpoint for 5 seconds, and samples
for 10 seconds by default. It reports the renderer and adapter,
average FPS, frame-time percentiles, draw calls and primitives at the end of
each sample. Hover picking and interior particles remain active. Fixed views
make comparisons repeatable, but do not represent all movement or shader
compilation stutters. Capture console output with the OS, driver, hypervisor,
VM 3D configuration and window resolution when comparing runs. Run several
times and compare like-for-like; headless or software rendering is not a GPU
benchmark.

The headless suite also exercises the main menu, all six selections, return to
the menu, region-only loading and optional regional vessels. `python3
tests/validate_assets.py` verifies regional mesh membership, cuts and triangle
counts. The Compatibility smoke test navigates the menu with controller events
renders both a focused view and the full model, and dispatches mouse capture,
release and motion events through Godot's input system.

Attribution: `python3 pipeline/sync_credits.py --check` verifies that the
in-app notice matches `ATTRIBUTION.txt`. The UI tests check both menu and
explorer credits and CI checks a Godot-exported pack in isolation.

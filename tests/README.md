# Testing and benchmarking

## Automated smoke tests

Install Godot **4.7.2**, then run from the repository root:

```sh
GODOT=/path/to/godot ./tests/run.sh
```

The runner imports the assets and checks startup at all three saved quality
levels, quality and mode transitions, ghost visibility, mesh availability, and
interior wrapping, and synthetic ray-picking cases. It exits nonzero on a failed check and uses a temporary XDG
data directory so it does not modify your saved settings. GitHub Actions runs
the same suite with the official 4.7.2 Linux binary and verifies its SHA-256.
CI also runs `render_smoke.gd` under Xvfb with Mesa software OpenGL to exercise
the Compatibility renderer and capture frames in each mode. This smoke test
does not establish visual correctness or measure physical-GPU performance.

`tour_test.gd` is an older manual, print-only smoke helper. `capture.gd` is a
manual screenshot helper. Both can be run as autoloads; see their comments.

## Graphics benchmark

First import the project in the editor (or run `godot --headless --editor --path
. --import`). On the target machine with a real graphical display, run:

```sh
GODOT=/path/to/godot ./tests/benchmark.sh performance --resolution 1280x720
GODOT=/path/to/godot BENCH_SCALE=0.5 ./tests/benchmark.sh performance --resolution 1280x720
GODOT=/path/to/godot ./tests/benchmark.sh performance --resolution 1280x720 --rendering-method gl_compatibility
```

Use `balanced` or `high` in place of `performance` to compare presets.
`BENCH_SCALE` accepts 0 (preset), 0.5, 0.65, 0.75, 0.9 or 1.0.
`BENCH_WARMUP` and `BENCH_DURATION` override the sample durations in seconds
(the defaults are recommended for comparisons). The
benchmark uses isolated settings, disables VSync, warms each fixed viewpoint
for 5 seconds, and samples for 10 seconds. It reports the renderer and adapter,
average FPS, frame-time percentiles, draw calls and primitives at the end of
each sample. Hover picking and interior particles remain active. Fixed views
make comparisons repeatable, but do not represent all movement or shader
compilation stutters. Capture console output with the OS, driver, hypervisor,
VM 3D configuration and window resolution when comparing runs. Run several
times and compare like-for-like; headless or software rendering is not a GPU
benchmark.

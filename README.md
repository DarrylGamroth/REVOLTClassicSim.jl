# REVOLTClassicSim.jl

`REVOLTClassicSim.jl` is the instrument-level REVOLT Classic simulation built
on [AdaptiveOpticsSim.jl](../AdaptiveOpticsSim.jl). It owns the Classic
Shack–Hartmann sensor graph, C-BLUE One IMX425 model, HSDM277 command geometry,
external-RTC boundary, and instrument-specific validation.

The package currently provides two explicitly provisional deformable-mirror
profiles:

- `:coordinate_gaussian` evaluates the supplied actuator coordinates;
- `:grid_gaussian` uses the equivalent separable 19×19 regular-grid model.

Neither profile is a measured HSDM277 influence calibration. Camera values not
present in the maintained unit configuration remain published-typical IMX425
values and are labeled accordingly in the graph files.

## Local use

```julia
using REVOLTClassicSim
using AdaptiveOpticsSim.AlgorithmGraphs

system = prepare_hil_system()
sequence = step_hil_frame!(system.boundary)
frame = hil_frame_buffer(system.boundary)
```

The default graph advances one deterministic five-layer atmosphere sample and
produces one complete 352×352 detector frame per step. A serialized external
RTC may return one complete 277-element command for adoption before the next
frame.

## Validation

```bash
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The opt-in process test calibrates this package's complete 277-command model
and closes its atmospheric loop through an independent pyRTC process using
pyRTC-compatible POSIX shared memory. Install the pinned official pyRTC
revision into an isolated Python environment, then run:

```bash
python3 -m venv .venv-pyrtc
.venv-pyrtc/bin/python -m pip install --upgrade pip
.venv-pyrtc/bin/python -m pip install -r test/pyrtc/requirements.txt

export PYRTC_PYTHON="$PWD/.venv-pyrtc/bin/python"
REVOLT_CLASSIC_PYRTC_TESTS=1 julia --startup-file=no --project=. \
  -e 'using Pkg; Pkg.test()'
```

The Python environment is not part of the package runtime and the test is not
run by default because it generates a full simulated interaction matrix.

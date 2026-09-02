# REVOLTClassicSim.jl

`REVOLTClassicSim.jl` is the instrument-level REVOLT Classic simulation built
on [AdaptiveOpticsSim.jl](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl).
It owns the Classic
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

Until these development packages are registered, clone AOS and this package as
sibling directories so the checked-in `[sources]` entry resolves:

```bash
mkdir revolt-classic-work
cd revolt-classic-work
git clone https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl.git
git clone https://github.com/DarrylGamroth/REVOLTClassicSim.jl.git
cd REVOLTClassicSim.jl
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
```

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

With the pinned pyRTC revision and deterministic SplitMix64 atmosphere seed,
the maintained gate retains 235 of 277 interaction directions at its 2%
singular-value cutoff. Over 500 atmospheric frames, the steady-state mean
on-axis Strehl increases from 0.0703 to 0.452 and pupil OPD RMS decreases from
262 nm to 106 nm. These values are regression references for this simulated
instrument, not measured REVOLT Classic performance.

## Frame-service benchmark

The package benchmark measures the serialized HIL service boundary: one
complete evolving-atmosphere graph step through a host-visible detector frame,
followed by immediate adoption of a zero RTC command. RTC computation and
fixed-arrival queueing are intentionally excluded. Run it with one Julia
thread; select `cpu`, `amdgpu`, or `cuda`. Accelerator runs default to one
captured device graph for the complete frame, while CPU runs use direct stream
execution. Set `REVOLT_BENCH_EXECUTION=stream` to make an explicit accelerator
diagnostic comparison. The harness defaults to 10 CPU warmup cycles and 200
accelerator warmup cycles so accelerator measurements exclude clock ramp-up
and first-replay effects:

```bash
julia --startup-file=no --project=benchmark \
  -e 'using Pkg; Pkg.instantiate()'

REVOLT_BENCH_BACKEND=cpu \
REVOLT_BENCH_SAMPLES=20 \
REVOLT_BENCH_RUNS=3 \
REVOLT_BENCH_OUTPUT=/tmp/revolt-classic-cpu.toml \
JULIA_NUM_THREADS=1 \
  julia --startup-file=no --project=benchmark benchmark/frame_service.jl
```

The TOML artifact records raw samples, preparation, warmed Julia allocation,
p50/p90 (and p99 only with at least 100 samples), mean frame and cycle rates,
source revisions, dirty state, runtime versions, hardware, affinity, and power
policy. These are self-paced service-cost measurements, not fixed-rate
deadline claims.

### Recorded results (2026-09-01)

| Backend | Execution | Mean frame rate | Mean HIL cycle rate | Frame p50 / p90 / p99 | Warmed Julia bytes/cycle |
|---|---|---:|---:|---:|---:|
| CPU | stream | 109.53 frames/s | 109.49 cycles/s | 8.974 / 9.383 / 13.411 ms | 0 |
| AMDGPU | captured HIP graph | 676.42 frames/s | 664.83 cycles/s | 1.439 / 1.667 / 2.062 ms | 0 |
| CUDA | captured CUDA graph | 1458.53 frames/s | 1373.17 cycles/s | 0.669 / 0.760 / 0.914 ms | 0 |

Each row contains three fresh prepared runs of 100 measured frames. CPU and
AMDGPU used ten warmup frames per run; the corrected CUDA result used 200. The
[CPU](benchmark/results/2026-09-01-cpu.toml),
[AMDGPU](benchmark/results/2026-09-01-amdgpu.toml), and
[CUDA](benchmark/results/2026-09-01-cuda.toml) artifacts contain the raw
samples and provenance.

The earlier CUDA artifact used CUDA.jl's task-coordinated stream wait at every
captured completion boundary. AdaptiveOpticsSim `aa3d934` selects direct
blocking stream completion only for capture-qualified execution, which cannot
contain host callbacks. The corrected row changes that completion mechanism;
the instrument graph and timed service boundary are unchanged.

CPU and AMDGPU ran on `rtc-devel` with an AMD Ryzen 7 6800H and its integrated
Rembrandt GPU. CUDA ran under WSL2 on `DGAMROTH-XPS` with an Intel Core
i7-12700H and RTX 3050 Ti Laptop GPU. These measurements therefore establish
the service cost on the available systems; they are not an isolated
AMD-versus-NVIDIA hardware comparison. Each process was pinned to one CPU, but
the recorded system load was not otherwise quiescent.

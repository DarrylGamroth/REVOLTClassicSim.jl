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
values and are labeled accordingly in the Julia graph builders.

Instrument topology and the shared production/calibration prescription are
constructed in Julia in [`src/graphs.jl`](src/graphs.jl). Both deformable-mirror
profiles use the same scientific settings. TOML is reserved for experiment
settings and calibration references; graph topology is defined by the Julia
builders.

## Local use

The simulation uses registered AdaptiveOpticsSim 0.2.1 and test-only
AdaptiveOpticsCalibration 0.17. Add General and the package registry, then
instantiate this checkout with Julia 1.12:

```bash
git clone https://github.com/DarrylGamroth/REVOLTClassicSim.jl.git
cd REVOLTClassicSim.jl
julia --startup-file=no --project=. -e '
using Pkg
Pkg.Registry.add("General")
Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/DarrylGamroth/PackageRegistry.git"))
Pkg.instantiate()'
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

## Shared PipeWire HIL transport

The optional transport uses released `AdaptiveOpticsSimPipeWireHIL` 0.2.2
and `PipeWireAO`. Install those packages in the application environment, then
attach the shared adapter to the prepared plant:

```julia
using REVOLTClassicSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.Backends: HostComputeDevice
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO

system = REVOLTClassicSim.prepare_hil_system(;
    target=HostComputeDevice(), execution=StreamGraphExecution())
configuration = REVOLTClassicSim.pipewire_configuration(system, "rtc-private";
    frame_node_name="revolt-classic-wfs", command_node_name="revolt-classic-command")
transport = AdaptiveOpticsSimPipeWireHIL.prepare_pipewire_hil(system.boundary, configuration)
# The application owns start!(transport), exchange_frame!(transport), and close(transport).
```

The defaults publish the 352×352 Float32 scientific detector schema
`org.revolt.classic.shwfs-frame.f32/1` and receive 277 Float32 HSDM277
surface-OPD commands in metres. The atmosphere advances by 2 ms per frame
(500 Hz); the detector exposure is 1.896 ms. Configuration reads these
values from the prepared context and detector plan and checks its boundary bindings. It does not
rebuild the plant. Native, HEART, and pyRTC controllers connect through the
ordinary PipeWireAO routes using compatible schemas, independently of this
plant package.

Operational UInt16 ADC frames require an explicit `frame_encoding=:uint16`
and `frame_schema="org.calculon.ao.raw-detector-pixels/1"`. Micrometre OPD commands
require both `command_schema="org.calculon.ao.demanded-pdm-command/1"`
and `command_scale=1f-6`; conversion is confined to transport. Float32 frame
schemas and metre commands remain the default scientific contract.

The existing REVOLT HEART deployment contract is selected explicitly with
`frame_encoding=:uint16`, `frame_schema="org.heart.std-wfs.raw-pixels/1"`,
`command_schema="org.heart.std-dm.actuator-command/1"`, and `command_scale=1`.
The pair retains that deployment's metre-OPD command meaning and HSDM277 order;
other HEART command meanings require a separately validated conversion.

The optional configuration checks run in their own dependency environment:

```bash
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 julia --startup-file=no --project=test/pipewire \
  -e 'using Pkg; Pkg.instantiate(); include("test/pipewire/runtests.jl")'
```

## Validation

```bash
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 julia --startup-file=no --project=. \
  -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The default suite includes physical graph checks and pure Julia AOC calibration
contract tests. It does not launch Python or require a pyRTC installation.
The plant-only HIL graphs connect to an external RTC through
AdaptiveOpticsSimPipeWireHIL; REVOLTRTC supplies the shared Classic/Copper
PipeWireAO deployment and the FGA/JFG controller graph.

The opt-in process test calibrates this package's complete 277-command model
and closes its atmospheric loop through an independent pyRTC process using
pyRTC-compatible POSIX shared memory. It keeps the ordered 554-exposure
positive/negative poke cycle, prepares the resulting 376×277 interaction matrix
with test-only `AdaptiveOpticsCalibration.jl`, and installs its 277×376
zero-Tikhonov, identity-weighted control matrix directly in pyRTC. The test
also checks the AOC interaction-matrix preparation against the former direct central difference and
the AOC reconstructor against both Julia and pyRTC-worker NumPy 2%-truncated
pseudoinverses before running the atmospheric gate. Install the pinned official
pyRTC revision into an isolated Python environment, then run:

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
The worker retains its historical `CONFIGURE` command for direct
interaction-matrix/pseudoinverse baseline checks; the maintained test selects
`CONFIGURE_CONTROL_MATRIX` for the AOC-prepared control matrix.

With the pinned pyRTC revision and deterministic SplitMix64 atmosphere seed,
the maintained gate retains 235 of 277 interaction directions at its 2%
singular-value cutoff. Over 500 atmospheric frames, the steady-state mean
on-axis Strehl increases from 0.0703 to 0.452 and pupil OPD RMS decreases from
262 nm to 106 nm. These values are regression references for this simulated
instrument, not measured REVOLT Classic performance.

### Live pyRTC viewer

With the same isolated pyRTC environment active, launch the actual REVOLT
Classic closed loop and its eight-pane viewer with:

```bash
export PYRTC_PYTHON="$PWD/.venv-pyrtc/bin/python"
julia --startup-file=no --project=test -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=test \
  test/pyrtc/run_revolt_classic_viewer.jl 300 10
```

The arguments are duration in seconds and requested HIL frame rate. The viewer
shows the 352×352 C-BLUE One frame, pyRTC slope product, physical 19×19
HSDM277 command map, uncompensated atmosphere OPD, PDM surface OPD, residual
OPD, and the open-loop and corrected science PSFs. Close the viewer window to
stop before the requested duration.

## Frame-service benchmark

The package benchmark measures the serialized HIL service boundary: one
complete evolving-atmosphere graph step through a host-visible detector frame,
followed by immediate adoption of a zero RTC command. RTC computation and
fixed-arrival queueing are intentionally excluded. Run it with one Julia
thread; select `cpu`, `amdgpu`, or `cuda`. Accelerator runs default to one
captured device graph for the complete frame, while CPU runs use direct stream
execution. The default benchmark environment supports CPU and CUDA 6.4.2; use
`benchmark/amdgpu` for AMDGPU so the accelerator stacks resolve independently.
Set `REVOLT_BENCH_EXECUTION=stream` to make an explicit accelerator diagnostic
comparison. The harness defaults to 10 CPU warmup cycles and 200 accelerator
warmup cycles so accelerator measurements exclude clock ramp-up and
first-replay effects:

```bash
julia --startup-file=no --project=benchmark \
  -e 'using Pkg; Pkg.instantiate()'

julia --startup-file=no --project=benchmark/amdgpu \
  -e 'using Pkg; Pkg.instantiate()'

REVOLT_BENCH_BACKEND=cpu \
REVOLT_BENCH_SAMPLES=20 \
REVOLT_BENCH_RUNS=3 \
REVOLT_BENCH_OUTPUT=/tmp/revolt-classic-cpu.toml \
JULIA_NUM_THREADS=1 \
  julia --startup-file=no --project=benchmark benchmark/frame_service.jl

REVOLT_BENCH_BACKEND=amdgpu \
REVOLT_BENCH_SAMPLES=20 \
REVOLT_BENCH_RUNS=3 \
REVOLT_BENCH_OUTPUT=/tmp/revolt-classic-amdgpu.toml \
JULIA_NUM_THREADS=1 \
  julia --startup-file=no --project=benchmark/amdgpu benchmark/frame_service.jl
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

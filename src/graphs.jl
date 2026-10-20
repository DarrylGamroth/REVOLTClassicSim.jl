# REVOLT Classic scientific plant graph prescription.
#
# The graph owns one explicitly timed five-layer atmosphere and advances it by
# 2 ms for every complete frame, matching the maintained 500 Hz camera setting.
# A serialized RTC adapter places one complete
# PDM command in the caller-owned command buffer before each graph step. This
# graph applies that command through an explicitly provisional
# continuous-facesheet model, composes the resulting surface OPD with the
# atmospheric OPD, forms the diffractive Shack-Hartmann photon-rate mosaic, and
# completes one noisy C-BLUE One IMX425 global-shutter CMOS frame suitable for
# publication through a transport adapter such as PipeWireAO.
#
# Optical values follow REVOLT/Python/specula/params_revolt_modal.yml. The
# detector identity, ROI, cadence, exposure, and gain follow the maintained
# HEART REVOLT configuration and its C-BLUE One IMX425 handler. The remaining
# detector values are published typical IMX425 characterization rather than
# unit calibration. The atmosphere profile follows the matching REVOLT OOPAO
# model and Julia common contract. The explicit RNG seed is an AOS
# reproducibility choice because those sources do not declare one.
# The exact 277-actuator command order comes from the matching 19-by-19 map
# payloads in the maintained on-sky and Copper branches. The Julia builder
# binds the normalized-pupil coordinates produced by
# `REVOLTClassicSim.actuator_coordinates`.
# REVOLT simulation sources place 17 actuator centres across the pupil and the
# OOPAO ideal profile uses 0.35 adjacent mechanical coupling; an older OOMAO
# script uses 0.30. Selecting 0.35 gives the provisional normalized Gaussian
# width of 0.08626550214129701.
# AX307_Influences.fits belongs to the 468-actuator BAX307/SPIDERS mirror, not
# HSDM277. Replace this analytic node with deformable_mirror_surface_node when a
# qualified HSDM277 sampled influence calibration is available.
#
# The PDM input contains one unit-peak actuator surface-OPD coefficient in
# metres per command element. It is not an ALPAO normalized hardware command; a
# transport adapter must apply a separately qualified command calibration
# before this graph boundary.

const _COMMAND_COUNT = 277
const _PUPIL_RESOLUTION = 240
const _TELESCOPE_DIAMETER_M = 1.22
const _CENTRAL_OBSTRUCTION_RATIO = 0.20491803278688525
const _SCIENCE_WAVELENGTH_M = 750.0e-9
const _ATMOSPHERE_STEP = 0.002
const _PDM_INFLUENCE_WIDTH = 0.08626550214129701
const _EXPOSURE_DURATION_S = 0.001896
const _SUPPORTED_PROFILES = (:coordinate_gaussian, :grid_gaussian)
const _ATMOSPHERE_OPD_SCHEMA = "org.revolt.classic.atmosphere-opd-m.f32/1"
const _PDM_COMMAND_SCHEMA = "org.revolt.hsdm277.actuator-surface-opd-m.f32/1"
const _PDM_SURFACE_OPD_SCHEMA = "org.revolt.hsdm277.pdm-surface-opd-m.f32/1"
const _PUPIL_OPD_SCHEMA = "org.revolt.classic.pupil-opd-m.f32/1"
const _PHOTON_RATE_SCHEMA = "org.revolt.classic.shwfs-photon-rate.f32/1"
const _FRAME_SCHEMA = "org.revolt.classic.shwfs-frame.f32/1"

"""Return the number of physical REVOLT Classic HSDM277 command elements."""
command_count() = _COMMAND_COUNT

"""Return the run-immutable deformable-mirror profiles supported by REVOLT Classic."""
supported_profiles() = _SUPPORTED_PROFILES

function _require_profile(profile::Symbol)
    profile in _SUPPORTED_PROFILES || throw(ArgumentError(
        "unsupported REVOLT Classic profile '$profile'; expected one of " *
        "$(join(_SUPPORTED_PROFILES, ", "))",
    ))
    return nothing
end

function _copy_to_target(target, values::AbstractArray)
    target_values = allocate_device_array(target, eltype(values), size(values)...)
    copyto!(target_values, values)
    return target_values
end

function _pdm_node(::Val{:coordinate_gaussian}, telescope)
    return gaussian_deformable_mirror_surface_node(
        :pdm; telescope..., actuator_count=command_count(),
        influence_width=_PDM_INFLUENCE_WIDTH,
        pdm_command_schema=_PDM_COMMAND_SCHEMA,
        surface_opd_schema=_PDM_SURFACE_OPD_SCHEMA,
        actuator_coordinates_schema="org.revolt.hsdm277.normalized-pupil-actuator-coordinates.f32/1",
    )
end

function _pdm_node(::Val{:grid_gaussian}, telescope)
    return grid_gaussian_deformable_mirror_surface_node(
        :pdm; telescope..., actuator_count=command_count(),
        actuator_axis_count=19, actuator_pitch=0.125,
        influence_width=_PDM_INFLUENCE_WIDTH,
        pdm_command_schema=_PDM_COMMAND_SCHEMA,
        surface_opd_schema=_PDM_SURFACE_OPD_SCHEMA,
        actuator_grid_indices_schema="org.revolt.hsdm277.actuator-grid-indices.i32/1",
    )
end

_pdm_parameter(::Val{:coordinate_gaussian}, target) = sparse_parameter(
    :pdm => :actuator_coordinates, _copy_to_target(target, actuator_coordinates()))
_pdm_parameter(::Val{:grid_gaussian}, target) = sparse_parameter(
    :pdm => :actuator_grid_indices, _copy_to_target(target, actuator_grid_indices()))

function _graph_definition(
    profile::Symbol,
    target;
    calibration::Bool=false,
    atmosphere_step::Real=_ATMOSPHERE_STEP,
    exposure_duration_s::Real=_EXPOSURE_DURATION_S,
)
    _require_profile(profile)
    telescope = (;
        resolution=_PUPIL_RESOLUTION,
        telescope_diameter_m=_TELESCOPE_DIAMETER_M,
        central_obstruction_ratio=_CENTRAL_OBSTRUCTION_RATIO,
        pupil_reflectivity=1.0, aperture_revision=1, T=Float32,
    )
    pdm = _pdm_node(Val(profile), telescope)
    pupil_opd_composition = pupil_opd_composition_node(
        :pupil_opd_composition;
        resolution=_PUPIL_RESOLUTION,
        uncompensated_opd_schema=_ATMOSPHERE_OPD_SCHEMA,
        surface_opd_schema=_PDM_SURFACE_OPD_SCHEMA,
        pupil_opd_schema=_PUPIL_OPD_SCHEMA,
        T=Float32,
    )
    shwfs = shack_hartmann_rate_node(
        :shwfs; telescope...,
        n_lenslets=16,
        n_pix_subap=22,
        diffraction_padding=2,
        pixel_scale_arcsec=0.697,
        valid_subaperture_threshold=0.1,
        threshold_convolution=0.05,
        half_pixel_shift=false,
        shannon_sampling=true,
        source_band=:R,
        source_magnitude=2.0,
        source_wavelength_m=8.0e-7,
        source_separation_arcsec=0.0,
        source_position_angle_deg=0.0,
        opd_schema=_PUPIL_OPD_SCHEMA,
        photon_rate_schema=_PHOTON_RATE_SCHEMA,
    )
    detector = cmos_detector_acquisition_node(
        :detector;
        rows=352,
        columns=352,
        binning=1,
        pixel_scale_arcsec=0.697,
        wavelength_m=8.0e-7,
        exposure_duration_s=exposure_duration_s,
        # Typical 20 °C IMX425 QE near 800 nm; not measured unit throughput.
        quantum_efficiency=0.27,
        # Camera 24 dB analogue gain expressed as 10^(24/20) voltage gain.
        gain=15.848931924611133,
        dark_current_e_per_pixel_s=calibration ? 0 : 0.96,
        # The maintained HEART snapshot does not state its pixel format.
        # Twelve-bit mode selects the published high-sensitivity values.
        bits=12,
        # Zero-gain image full well also supplies the ADC scale; 24 dB clips sooner.
        full_well_e=94000.0,
        photon_noise=!calibration,
        readout_noise=!calibration,
        # Published RMS for 12-bit high-sensitivity operation at 24 dB.
        readout_noise_e=calibration ? 0 : 2.33,
        column_readout_noise_e=0.0,
        row_readout_noise_e=0.0,
        rng_seed=0,
        photon_rate_schema=_PHOTON_RATE_SCHEMA,
        frame_schema=_FRAME_SCHEMA,
        T=Float32,
    )

    command = graph_input(:pdm_command, :pdm => :pdm_command,
        _copy_to_target(target, zeros(Float32, command_count())))
    pdm_output = graph_output(:pdm_surface_opd, :pdm => :surface_opd)
    sensor_outputs = (
        graph_output(:pupil_opd, :pupil_opd_composition => :pupil_opd),
        graph_output(:shwfs_photon_rate, :shwfs => :photon_rate),
        graph_output(:shwfs_frame, :detector => :frame),
    )
    surface_link = link(:pdm => :surface_opd, :pupil_opd_composition => :surface_opd)
    sensor_links = (
        link(:pupil_opd_composition => :pupil_opd, :shwfs => :opd),
        link(:shwfs => :photon_rate, :detector => :photon_rate),
    )
    sensor_nodes = (pdm, pupil_opd_composition, shwfs, detector)
    if calibration
        uncompensated_opd = _copy_to_target(target,
            zeros(Float32, _PUPIL_RESOLUTION, _PUPIL_RESOLUTION))
        nodes = sensor_nodes
        inputs = (command, graph_input(:uncompensated_opd,
            :pupil_opd_composition => :uncompensated_opd, uncompensated_opd))
        outputs = (pdm_output, sensor_outputs...)
        links = (surface_link, sensor_links...)
        name = :revolt_classic_hil_calibration
    else
        atmosphere = multilayer_atmosphere_opd_node(
            :atmosphere; telescope...,
            r0=0.15,
            reference_wavelength_m=5.0e-7,
            L0=30.0,
            fractional_cn2=[0.45, 0.1, 0.1, 0.25, 0.1],
            wind_speed=[5.0, 5.0, 7.0, 10.0, 10.0],
            wind_direction_deg=[0.0, 72.0, 144.0, 216.0, 288.0],
            altitude=[0.0, 1000.0, 5000.0, 10000.0, 12000.0],
            layer_ids=[:revolt_ground, :revolt_1km, :revolt_5km, :revolt_10km, :revolt_12km],
            atmosphere_step=atmosphere_step,
            rng_seed=1,
            atmosphere_opd_schema=_ATMOSPHERE_OPD_SCHEMA,
        )
        nodes = (atmosphere, sensor_nodes...)
        inputs = (command,)
        outputs = (pdm_output,
            graph_output(:atmosphere_opd, :atmosphere => :atmosphere_opd),
            sensor_outputs...)
        links = (surface_link,
            link(:atmosphere => :atmosphere_opd,
                :pupil_opd_composition => :uncompensated_opd),
            sensor_links...)
        name = Symbol(:revolt_classic_hil_, profile)
    end
    return algorithm_graph(nodes; name, inputs, outputs, links,
        parameters=(_pdm_parameter(Val(profile), target),))
end

function _prepare_system(profile, target, execution; calibration::Bool=false)
    definition = _graph_definition(profile, target; calibration)
    graph = prepare_algorithm_graph(definition; target, execution)
    boundary = prepare_graph_hil_boundary(graph;
        command_input=:pdm_command, frame_output=:shwfs_frame)
    frame_period_s = Float32(_ATMOSPHERE_STEP)
    if calibration
        uncompensated_opd = graph_input(graph, :uncompensated_opd)
        return (; graph, boundary, frame_period_s, uncompensated_opd)
    end
    return (; graph, boundary, frame_period_s)
end

"""
    prepare_hil_system(; profile=:grid_gaussian,
        target=HostComputeDevice(), execution=StreamGraphExecution())

Prepare the atmosphere-backed REVOLT Classic Julia graph and its serialized
277-command/352×352-frame HIL boundary. `profile` selects the coordinate or
separable-grid implementation of the same provisional HSDM277 response.
`frame_period_s` records the run-immutable model cadence independently of the
detector exposure. Command and frame buffers remain owned by the boundary.
"""
function prepare_hil_system(;
    profile::Symbol=:grid_gaussian,
    target=HostComputeDevice(),
    execution=StreamGraphExecution(),
)
    return _prepare_system(profile, target, execution)
end

"""
    prepare_calibration_system(; profile=:grid_gaussian,
        target=HostComputeDevice(), execution=StreamGraphExecution())

Prepare the same REVOLT Classic prescription with a flat `uncompensated_opd`
input and noiseless detector for a simulation-local interaction matrix. The
provisional HSDM277 model and sensor geometry are shared with production; this
is not a measured instrument calibration or a qualified pixel reconstructor.
"""
function prepare_calibration_system(;
    profile::Symbol=:grid_gaussian,
    target=HostComputeDevice(),
    execution=StreamGraphExecution(),
)
    return _prepare_system(profile, target, execution; calibration=true)
end

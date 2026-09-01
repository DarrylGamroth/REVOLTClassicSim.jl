const _COMMAND_COUNT = 277
const _PUPIL_RESOLUTION = 240
const _TELESCOPE_DIAMETER_M = 1.22
const _CENTRAL_OBSTRUCTION_RATIO = 0.20491803278688525
const _SCIENCE_WAVELENGTH_M = 750.0e-9
const _LENSLET_ROW_WIDTHS = (
    4,
    8,
    10,
    12,
    14,
    14,
    16,
    16,
    16,
    16,
    14,
    14,
    12,
    10,
    8,
    4,
)

"""Return the number of physical REVOLT Classic HSDM277 command elements."""
command_count() = _COMMAND_COUNT

"""
    valid_subapertures()

Return the exact 16×16 REVOLT Classic valid-subaperture mask. Its 188 selected
lenslets reproduce `validSubapMask.fits` from the maintained on-sky
configuration (raw SHA-256
`720bf7aa82d098e1bc5426b3364dd509adc609617b23127351d4d750b0ff596e`).
"""
function valid_subapertures()
    mask = falses(16, 16)
    for (row, width) in pairs(_LENSLET_ROW_WIDTHS)
        first_column = (size(mask, 2) - width) ÷ 2 + 1
        last_column = first_column + width - 1
        @views fill!(mask[row, first_column:last_column], true)
    end
    return mask
end

function _calibration_detector(production_detector)
    config = production_detector.config
    return cmos_detector_acquisition_node(
        :detector;
        rows=config.rows,
        columns=config.columns,
        binning=config.binning,
        pixel_scale_arcsec=config.pixel_scale_arcsec,
        wavelength_m=config.wavelength_m,
        exposure_duration_s=config.exposure_duration_s,
        quantum_efficiency=config.quantum_efficiency,
        gain=config.gain,
        dark_current_e_per_pixel_s=0,
        bits=config.bits,
        full_well_e=config.full_well_e,
        photon_noise=false,
        readout_noise=false,
        readout_noise_e=0,
        column_readout_noise_e=0,
        row_readout_noise_e=0,
        rng_seed=config.rng_seed,
        photon_rate_schema=config.photon_rate_schema,
        frame_schema=config.frame_schema,
        T=Float32,
    )
end

"""
    prepare_calibration_system(; profile=:grid_gaussian,
        target=HostComputeDevice(), execution=StreamGraphExecution())

Prepare a flat, noiseless REVOLT Classic graph for a simulation-local
interaction matrix. It retains the selected provisional HSDM277 model and the
production Shack–Hartmann/CMOS geometry, but it is not an instrument
calibration.
"""
function prepare_calibration_system(;
    profile::Symbol=:grid_gaussian,
    target=HostComputeDevice(),
    execution=StreamGraphExecution(),
)
    production = _graph_definition(profile, target)
    length(production.nodes) == 5 || error(
        "the maintained REVOLT Classic HIL graph must contain five nodes",
    )
    pdm = production.nodes[2]
    composition = production.nodes[3]
    shwfs = production.nodes[4]
    detector = _calibration_detector(production.nodes[5])
    uncompensated_opd = _copy_to_target(
        target,
        zeros(Float32, _PUPIL_RESOLUTION, _PUPIL_RESOLUTION),
    )
    definition = algorithm_graph(
        (pdm, composition, shwfs, detector);
        name=:revolt_classic_hil_calibration,
        inputs=(
            first(production.inputs),
            graph_input(
                :uncompensated_opd,
                :pupil_opd_composition => :uncompensated_opd,
                uncompensated_opd,
            ),
        ),
        outputs=(
            graph_output(:pdm_surface_opd, :pdm => :surface_opd),
            graph_output(:pupil_opd, :pupil_opd_composition => :pupil_opd),
            graph_output(:shwfs_photon_rate, :shwfs => :photon_rate),
            graph_output(:shwfs_frame, :detector => :frame),
        ),
        links=(
            link(
                :pdm => :surface_opd,
                :pupil_opd_composition => :surface_opd,
            ),
            link(:pupil_opd_composition => :pupil_opd, :shwfs => :opd),
            link(:shwfs => :photon_rate, :detector => :photon_rate),
        ),
        parameters=production.parameters,
    )
    graph = prepare_algorithm_graph(definition; target, execution)
    boundary = prepare_graph_hil_boundary(
        graph;
        command_input=:pdm_command,
        frame_output=:shwfs_frame,
    )
    return (; graph, boundary, uncompensated_opd)
end

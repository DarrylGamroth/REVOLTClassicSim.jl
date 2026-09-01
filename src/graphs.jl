const _GRAPH_DIRECTORY = normpath(joinpath(pkgdir(REVOLTClassicSim), "graphs"))
const _SUPPORTED_PROFILES = (:coordinate_gaussian, :grid_gaussian)

"""Return the run-immutable deformable-mirror profiles supported by REVOLT Classic."""
supported_profiles() = _SUPPORTED_PROFILES

@inline _graph_filename(::Val{:coordinate_gaussian}) =
    "revolt_classic_hil_coordinate_gaussian.toml"
@inline _graph_filename(::Val{:grid_gaussian}) =
    "revolt_classic_hil_grid_gaussian.toml"

"""
    graph_path([profile=:grid_gaussian])

Return the maintained REVOLT Classic external-RTC graph for `profile`.
`coordinate_gaussian` evaluates the provisional HSDM277 response from actuator
coordinates. `grid_gaussian` uses the equivalent separable regular-grid
evaluation. The profile is fixed before graph preparation.
"""
function graph_path(profile::Symbol=:grid_gaussian)
    profile in _SUPPORTED_PROFILES || throw(ArgumentError(
        "unsupported REVOLT Classic profile '$profile'; expected one of " *
        "$(join(_SUPPORTED_PROFILES, ", "))",
    ))
    return joinpath(_GRAPH_DIRECTORY, _graph_filename(Val(profile)))
end

"""Return the REVOLT Classic in-process RTC-reference graph path."""
rtc_reference_graph_path() =
    joinpath(_GRAPH_DIRECTORY, "revolt_classic_rtc_reference.toml")

function _copy_to_target(target, values::AbstractArray)
    target_values = allocate_device_array(
        target,
        eltype(values),
        size(values)...,
    )
    copyto!(target_values, values)
    return target_values
end

function _graph_bindings(profile::Symbol, target)
    pdm_command = _copy_to_target(
        target,
        zeros(Float32, command_count()),
    )
    if profile === :coordinate_gaussian
        pdm_actuator_coordinates = _copy_to_target(
            target,
            actuator_coordinates(),
        )
        return (; pdm_command, pdm_actuator_coordinates)
    elseif profile === :grid_gaussian
        pdm_actuator_grid_indices = _copy_to_target(
            target,
            actuator_grid_indices(),
        )
        return (; pdm_command, pdm_actuator_grid_indices)
    end
    graph_path(profile)
    error("unreachable REVOLT Classic profile")
end

function _graph_definition(profile::Symbol, target)
    return load_algorithm_graph(
        graph_path(profile);
        bindings=_graph_bindings(profile, target),
    )
end

"""
    prepare_hil_system(; profile=:grid_gaussian,
        target=HostComputeDevice(), execution=StreamGraphExecution())

Prepare the atmosphere-backed REVOLT Classic detector graph and its serialized
277-command/352×352-frame HIL boundary. The returned command and frame buffers
remain owned by the prepared boundary.
"""
function prepare_hil_system(;
    profile::Symbol=:grid_gaussian,
    target=HostComputeDevice(),
    execution=StreamGraphExecution(),
)
    graph = prepare_algorithm_graph(
        _graph_definition(profile, target);
        target,
        execution,
    )
    boundary = prepare_graph_hil_boundary(
        graph;
        command_input=:pdm_command,
        frame_output=:shwfs_frame,
    )
    return (; graph, boundary)
end

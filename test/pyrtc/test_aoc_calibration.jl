using Test

include(joinpath(@__DIR__, "pyrtc_process_hil.jl"))
using .PyRTCProcessHIL

@testset "REVOLT Classic AOC push-pull calibration layout" begin
    # Exposure rows preserve the external HSDM277 order: +command 1,
    # -command 1, +command 2, -command 2, and so on.
    responses = Float32[
        6 2
        2 -2
        -1 9
        -5 1
        10 3
        2 7
    ]
    expected = Float32[
        1 1 2
        1 2 -1
    ]
    direct = PyRTCProcessHIL.direct_central_difference_interaction_matrix(
        responses,
        2f0,
    )
    interaction_matrix = PyRTCProcessHIL.interaction_matrix_from_responses(
        responses,
        2f0,
    )
    @test direct == expected
    @test interaction_matrix == expected
    @test size(interaction_matrix) == (2, 3)
    @test eltype(interaction_matrix) === Float32
end

@testset "REVOLT Classic AOC calibration contracts" begin
    definition = PyRTCProcessHIL.process_definition()
    @test definition.command_count == 277
    @test definition.signal_shape == (376,)
    @test 2 * definition.command_count == 554
    @test definition.control_rcond == 0.02f0

    @test_throws DimensionMismatch PyRTCProcessHIL.direct_central_difference_interaction_matrix(
        zeros(Float32, 3, 2),
        definition.poke,
    )
    @test_throws ArgumentError PyRTCProcessHIL.interaction_matrix_from_responses(
        zeros(Float32, 2, 1),
        0f0,
    )
    @test_throws ArgumentError PyRTCProcessHIL.interaction_matrix_from_responses(
        reshape(Float32[NaN, 0], 2, 1),
        definition.poke,
    )
    @test_throws DimensionMismatch PyRTCProcessHIL.prepare_aoc_control_matrix(
        zeros(Float32, 2, 1),
        definition,
    )

    command = PyRTCProcessHIL.worker_command(definition, tempdir())
    @test command.exec[2] == joinpath(@__DIR__, "pyrtc_process_worker.py")
    @test command.exec[3:4] == ["--system", "revolt_classic"]
end


function synthetic_full_dimension_responses(definition)
    measurement_count = only(definition.signal_shape)
    command_count = definition.command_count
    interaction = zeros(Float32, measurement_count, command_count)
    for command in 1:command_count
        singular_value = command <= 4 ? 1.0f0 :
            command <= 7 ? 0.0625f0 : 0.0078125f0
        interaction[command, command] = singular_value
    end
    responses = zeros(Float32, 2 * command_count, measurement_count)
    for command in 1:command_count
        @views responses[2 * command - 1, :] .=
            definition.poke .* interaction[:, command]
        @views responses[2 * command, :] .=
            -definition.poke .* interaction[:, command]
    end
    return interaction, responses
end

@testset "REVOLT Classic full-dimension AOC spectrum" begin
    definition = PyRTCProcessHIL.process_definition()
    reference, responses = synthetic_full_dimension_responses(definition)
    products = PyRTCProcessHIL.prepare_aoc_control_matrix(responses, definition)

    @test size(products.interaction_matrix) == (376, 277)
    @test size(products.control_matrix) == (277, 376)
    @test products.retained_interaction_rank == 7
    @test products.interaction_matrix_relative_error < 5f-6
    @test products.control_matrix_relative_error < 5f-5
    @test products.interaction_matrix ≈ reference rtol=5f-6
    @info "Classic synthetic AOC calibration" dimensions=size(reference) retained_rank=products.retained_interaction_rank interaction_relative_error=products.interaction_matrix_relative_error control_relative_error=products.control_matrix_relative_error
end

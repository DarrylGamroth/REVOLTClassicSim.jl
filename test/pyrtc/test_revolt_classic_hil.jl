using Test

include(joinpath(@__DIR__, "pyrtc_process_hil.jl"))
using .PyRTCProcessHIL

@testset "REVOLT Classic viewer command geometry" begin
    display = PyRTCProcessHIL.command_display()
    command = zeros(Float32, REVOLTClassicSim.command_count())
    command[139] = 1.0f0
    PyRTCProcessHIL.update_command_display!(display, command)
    @test size(display.values) == (19, 19)
    @test display.values[10, 10] == 1.0f0
    @test count(!iszero, display.values) == 1
    @test (@allocated PyRTCProcessHIL.update_command_display!(
        display,
        command,
    )) == 0
end

@testset "REVOLT Classic closes through a pyRTC process" begin
    result = PyRTCProcessHIL.run_revolt_classic_validation()
    @test result.system === :revolt_classic
    @test result.frame_shape == (352, 352)
    @test result.signal_length == 376
    @test result.command_count == 277
    @test result.retained_interaction_rank >= 221
    @test isfinite(result.retained_interaction_condition)
    @test isfinite(result.numerical_interaction_condition)
    @test 0 < result.mean_open_loop_on_axis_strehl < 1
    @test 0.35 < result.mean_closed_loop_on_axis_strehl <= 1
    @test result.improvement >
        PyRTCProcessHIL.REVOLT_CLASSIC_MINIMUM_STREHL_IMPROVEMENT
    @test result.mean_residual_opd_rms_m <
        0.5 * result.mean_uncompensated_opd_rms_m
    @test isfinite(result.mean_pdm_command_rms_m)
end

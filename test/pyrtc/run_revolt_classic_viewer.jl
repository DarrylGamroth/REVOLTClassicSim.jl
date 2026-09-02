include(joinpath(@__DIR__, "pyrtc_process_hil.jl"))

duration = isempty(ARGS) ? 120.0 : parse(Float64, ARGS[1])
frame_rate = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 10.0

PyRTCProcessHIL.revolt_classic_viewer_main(; duration, frame_rate)

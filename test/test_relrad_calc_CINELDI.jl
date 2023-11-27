using SintPowerGraphs
using JLD2

network_filename = joinpath(@__DIR__, "../examples/reliability_course/excel_test.toml")
cost_filename = joinpath(@__DIR__, "../databases/cost_functions.json")

cost_functions = read_cost_functions(cost_filename)
network =  RadialPowerGraph(network_filename)

res, _, _ = relrad_calc(cost_functions, network)
IC = res["base"].CENS
ICt = res["temp"].CENS
IC_sum = sum(IC;dims=2)
ICt_sum = sum(ICt;dims=2)
println(IC_sum)
println(ICt_sum)


IC_sum_target = [265.75; 274.78; 227.7; 166.24]
@testset "Verifying unavailability" begin
U_target = 13.15
@test isapprox(sum(res["base"].U), U_target)
end

epsilon = 0.9
@test isapprox(sum(IC_sum), sum(IC_sum_target), atol=epsilon)

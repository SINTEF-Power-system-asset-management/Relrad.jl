using RelDist
using SintPowerGraphs
using DataFrames

network_filename = joinpath(@__DIR__, "CINELDI.toml")
cost_filename = joinpath(@__DIR__, "../../databases/cost_functions.json")

cost_functions = read_cost_functions(cost_filename)

network = RadialPowerGraph(network_filename)

# The names in the CINELDI dataframe are not the same as what is expected.
rename!(network.mpc.reldata, :r_perm => :repairTime)
rename!(network.mpc.reldata, :r_temp => :temporaryFaultTime)
rename!(network.mpc.reldata, :lambda_perm => :permanentFaultFrequency)
rename!(network.mpc.reldata, :lambda_temp => :temporaryFaultFrequency)

rename!(network.mpc.reldata, :sectioning_time => :sectioningTime)

res, rest, L, edge_pos = relrad_calc(cost_functions, network)

resframe = ResFrames(res, rest, edge_pos, L)


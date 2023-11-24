using Graphs
using SintPowerGraphs
using DataFrames
using MetaGraphs
using Logging


"""
    relrad_calc(cost_functions::Dict{String, PieceWiseCost}, network::RadialPowerGraph)

        Returns the load interruption costs

        # Arguments
        - cost_functions: Dictionary with cost information
        - network: Data Structure with network data

        # Output
        - res: Costs for permanent interruption, defined for each load and each failed branch
        - resₜ: Costs for temporary interruption, defined for each load and each failed branch
"""
function relrad_calc(cost_functions::Dict{String, PieceWiseCost}, 
                    network::RadialPowerGraph,
                    config::RelDistConf=RelDistConf(),
                    filtered_branches=DataFrame(element=[], f_bus=[],t_bus=[], tag=[]))
    Q = []  # Empty arrayj
	L = get_loads(network.mpc)
    edge_pos_df = store_edge_pos(network)
    res = Dict("temp" => RelStruct(length(L), nrow(network.mpc.branch)))
    # Set missing automatic switching timtes to zero
    network.mpc.switch.t_remote .= coalesce.(network.mpc.switch.t_remote, Inf)

    # Define the cases we are going to run
    cases = ["base"]
    
    # the probability of the base case if we don't have any other cases.
    base_prob = 1
    
    if config.failures.switch_failure_prob > 0
        for case in ["upstream", "downstream"] 
            res[case] = RelStruct(length(L), nrow(network.mpc.branch),
                                 config.failures.switch_failure_prob)
            push!(cases, case)
            base_prob -= config.failures.switch_failure_prob
        end
    end
    
    if config.failures.communication_failure_prob > 0
        # This case is not run in the section function. I therefore,
        # don't add it to the  case list.
        res["comm_fail"] = RelStruct(length(L), nrow(network.mpc.branch),
                                    config.failures.communication_failure_prob)
        base_prob -= config.failures.communication_failure_prob
    end

    push_adj(Q, network.radial, network.radial[network.ref_bus, :name])
    # I explore only the original radial topology for failures effect (avoid loops of undirected graph)
    i = 0
    F = get_slack(network, config.traverse.consider_cap) # get list of substations (not distribution transformers). If not present, I use as slack the slack bus declared
    
    if config.failures.reserve_failure_prob > 0
        for f in F
            if !slack_is_ref_bus(network, f)
                name = "reserve_"*create_slack_name(f)
                res[name] = RelStruct(length(L), nrow(network.mpc.branch),
                                     config.failures.reserve_failure_prob)
                push!(cases, name)
                base_prob -= config.failures.reserve_failure_prob
            end
        end
    end

    res["base"] = RelStruct(length(L), nrow(network.mpc.branch))

    
    while !isempty(Q)
        e = pop!(Q)
        @info "Processing line $e"
        edge_pos = get_edge_pos(e,edge_pos_df, filtered_branches)
        rel_data = get_branch_data(network, :reldata, e.src, e.dst)
        
        section!(res, cost_functions, network, edge_pos, e, L, F, cases, config.failures)
        
        l_pos = 0
        for l in L

            l_pos += 1
            set_rel_res!(res["temp"],
                         rel_data.temporaryFaultFrequency[1],
                         rel_data.temporaryFaultTime[1],
                         l.P,
                         cost_functions[l.type],
                         l_pos, edge_pos)
        end
        push_adj(Q, network.radial, e)
    end
    return res, L, edge_pos_df
end


"""
    section(cost_functions::Dict{String, PieceWiseCost},
            network::RadialPowerGraph,
            net_map::graphMap,
            res::RelStruc,
            e::Graphs.SimpleGraphs.SimpleEdge{Int64},
            L::Array)

            Performs the sectioning of the branch and returns the permanent interruption costs

            # Arguments
            - cost_functions: Dictionary with cost information
            - network: Data Structure with network data
            - net_map:: Data structure with graph-network mapping
            - e: failed network edge
            - L: Array of loads
"""
function section!(res::Dict{String, RelStruct},
        cost_functions::Dict{String, PieceWiseCost},
        network::RadialPowerGraph,
        edge_pos::Int,
        e::Branch,
        L::Array,
        F::Array,
        cases::Array,
        failures::Failures)
    
    repair_time = get_branch_data(network, :reldata, e.src, e.dst).repairTime
    permanent_failure_frequency = get_branch_data(network, :reldata, e.src, e.dst).permanentFaultFrequency[1]

    if permanent_failure_frequency >= 0
        reconfigured_network, isolating_switches, isolated_edges, backup_switches = traverse_and_get_sectioning_time(network, e, failures.switch_failure_prob>0)
        for (i, case) in enumerate(cases)
            R_set = []
            # For the cases with switch failures we remove the extra edges
            if case ∈ ["upstream", "downstream"]
                isolating_switch = backup_switches[i-1]
                for e in isolated_edges[i-1]
                    rem_edge!(reconfigured_network, e)
                end
            else
                isolating_switch = isolating_switches[1] < isolating_switches[2] ? isolating_switches[2] : isolating_switches[1]
            end
            for f in F
                # If we are considering reserve failures and the name of the reserve
                # is the same as the case, we will skip to add the reachable loads
                # to the reachable matrix.
                if !(failures.reserve_failure_prob > 0.0 && "reserve_"*create_slack_name(f) == case)
                    R = Set(calc_R(network, reconfigured_network, f))
                    push!(R_set, R)
                end
            end
            if case ∈ ["upstream", "downstream"]
                for e in isolated_edges[i-1]
                    add_edge!(reconfigured_network, e)
                end
            end

            res[case].switch_u[edge_pos] = isolating_switches[1]
            res[case].switch_d[edge_pos] = isolating_switches[2]

            X = union(R_set...)

            l_pos = 0
            for l in L
                l_pos += 1;
                if !(l.bus in X) 
                    t = repair_time
                else
                    t = get_minimum_switching_time(isolating_switch)
                end
                set_rel_res!(res[case], permanent_failure_frequency, t[1],
                             l.P, cost_functions[l.type],
                             l_pos, edge_pos)
                # In case we are considering communication failures we have the same 
                # isolated network as in the base case. 
                if failures.communication_failure_prob > 0 && case == "base"
                    # In case we the outage time is not equal to the component repair time 
                    # set it to the manual switching time of the isolating switch.
                    if  t != repair_time 
                        t = isolating_switch.t_manual
                    end
                    set_rel_res!(res["comm_fail"], permanent_failure_frequency,
                                 t[1], l.P, cost_functions[l.type],
                                 l_pos, edge_pos)
                end
            end
        end
    else
        return # If the line has no permanent failure frequency we skip it.
    end
end

function get_switch(network::RadialPowerGraph, e::Edge)
    get_switch(network, edge2branch(network.G, e))
end

function get_switch(network::RadialPowerGraph, e::Branch)
    get_switch(network.mpc, e)
end

function get_switch(mpc::Case, e::Branch)
    switches = mpc.switch[mpc.switch.f_bus.==e.src .&& mpc.switch.t_bus.==e.dst, :]
    if isempty(switches)
        return Switch(e.src, e.dst, -Inf, -Inf)
    end
    # If any of the swithces are not remote. I assume that the slowest switch
    # available for siwtching is a manual switch. If all swithces are remote
    # I assume that the slowst switch is a remote switch
    drop_switch = switches.t_remote.==Inf
    if any(drop_switch)
        # There is at least one switch that is not remote
        idx = findmax(switches[drop_switch, :t_manual])[2]
        switch = switches[drop_switch, :][idx, :]
    else
        idx = findmax(switches.t_remote)[2]
        switch = switches[idx, :]
    end
    return Switch(switch.f_bus, switch.t_bus, switch.t_manual, switch.t_remote)
end

function get_names(mg)
    names = []
    for bus in 1:nv(mg)
        append!(names, [get_prop(mg, bus, :name)])
    end
    return names
end

function myplot(network, names)
    graphplot(network, names = names, nodeshape=:circle, nodesize=0.1, curves=false, fontsize=7)
end

""" Calculate reachable vertices starting from a given edge"""
function calc_R(network::RadialPowerGraph,
                g::MetaGraph,
                e::Branch)::Array{Any}
    v = get_node_number(network.G, e.dst)
    vlist = traverse(g, v, e.rateA)
    return [get_bus_name(network.G, bus) for bus in vlist]
end

""" Calculate reachable vertices starting from a given edge"""
function calc_R(network::RadialPowerGraph,
                g::MetaGraph,
                b::Feeder)::Array{Any}
    v = get_node_number(network.G, b.bus)
    vlist = traverse(g, v, b.rateA)
    return [get_bus_name(network.G, bus) for bus in vlist]
end


function traverse(g::MetaGraph, start::Int = 0,
        feeder_cap::Real=Inf, dfs::Bool = true)::Vector{Int}
    seen = Vector{Int}()
    visit = Vector{Int}([start])
    load = 0

    @assert start in vertices(g) "can't access $start in $(props(g, 1))"
    while !isempty(visit)
        next = pop!(visit)
        load += get_prop(g, next, :load)
        if load > feeder_cap
            return seen
        end
        if !(next in seen)
            for n in neighbors(g, next)
                if !(n in seen)
                    if dfs append!(visit, n) else insert!(visit, 1, n) end
                end
            end
            push!(seen, next)
        end
    end
    return seen
end

"""
    Traverse the in a direction until all isolating switches are found.
"""
function find_isolating_switches!(network::RadialPowerGraph, g::MetaDiGraph,
        reconfigured_network::MetaGraph, visit::Vector{Int}, seen::Vector{Int})
    # Initialise variable to keep track of sectioning time
    isolating_switches = Vector{Switch}()
   
    while !isempty(visit)
        next = pop!(visit)
        if !(next in seen)
            push!(seen, next)
            for n in setdiff(all_neighbors(g, next), seen)
                e = Edge(next, n) in edges(g) ? Edge(next, n) : Edge(n, next)
                
                rem_edge!(reconfigured_network, e)
  
                if get_prop(g, e, :switch) == -1 # it is not a switch, I keep exploring the graph
                    append!(visit, n)
                else
                    # it is a switch, I stop exploring the graph in this direction
                    push!(seen, n) 
                    # We are at the depth of the first isolating switch(es)
                    push!(isolating_switches(get_switch(network, e))
                end
            end
        end
    end
    return isolating_switches
end

"""
    traverse_and_get_sectioning_time

    Finds the switch that isolates a fault and the part of the network connected to
    this switch.
"""
function traverse_and_get_sectioning_time(network::RadialPowerGraph, e::Branch,
    switch_failures::Bool=false)
    # isolated_edges = []
	g = network.G
	reconfigured_network = MetaGraph(copy(network.G)) # This graph must be undirected
    
    # Remove the edge from the reconfigured network
    rem_edge!(reconfigured_network, Edge(s, n))

    s = get_node_number(network.G, string(e.src))
    n = get_node_number(network.G, e.dst)
    switch_buses = get_prop(g, Edge(s, n), :switch_buses)
    # If we consider switch failures we always have to search up and
    # downstream.
    
    if length(switch_buses) >= 1
        # There is at least one switch on the branch
        if e.src ∈ switch_buses
            # There is a switch at the source, we don't have to search upstream
            switch_u = [get_switch(network, e)]
        else
            # Search upstream for a switch
            switch_u = find_isolating_switches!(network, g, reconfigured_network, 
                                                [s], [n])
        end
        if e.dst ∈ switch_buses
            # There is a switch at the destination, we don't have to search downstream
            switch_d = [get_switch(network, e)]
        else
            # Search upstream for a switch
            switch_d = find_isolating_switches!(network, g, reconfigured_network, 
                                                [n], [s])
        end
    end
    if switch_failures
        Write code here that runts find_isolating_switches for each of the
        isloating swithces to find the backup switches

    return reconfigured_network, [switch_u, switch_d], [isolated_upstream, isolated_downstream], [backup_upstream, backup_downstream]
end


function push_adj(Q::Array{Any,1}, g::AbstractMetaGraph, v::Int)
    # it takes as input the graph VERTEX v, it stores in Q the list of Power BRANCHES adjacent of v
    successors = neighbors(g, v)
    for i in successors
        push!(Q, edge2branch(g, Edge(v,i))) # Edge(get_bus_name(network,v), get_bus_name(network,i)))
    end
end

function push_adj(Q::Array{Any,1}, g::AbstractMetaGraph, e::Branch)
    v = get_node_number(g, e.dst) # t_bus in the graph notation
    push_adj(Q, g, v)
end

function get_bus_name(g, vertex)
	 g[vertex, :name]
end

function get_node_number(g, bus)
    g[bus, :name]
end

function store_edge_pos(network::RadialPowerGraph)
    if "name" in names(network.mpc.branch)
        return insertcols!(select(network.mpc.branch, "f_bus"=>"f_bus", "t_bus"=>"t_bus", "name"=>"name"), 1,:index =>1:size(network.mpc.branch)[1])
    elseif "ID" in names(network.mpc.branch)
        return insertcols!(select(network.mpc.branch, "f_bus"=>"f_bus", "t_bus"=>"t_bus", "ID"=>"name"), 1,:index =>1:size(network.mpc.branch)[1])
    else
        # Here I am creating artificially a name column equal to the index
        return insertcols!(insertcols!(select(network.mpc.branch, "f_bus"=>"f_bus", "t_bus"=>"t_bus"),1,:name=>string.(1:size(network.mpc.branch, 1))), 1,:index =>1:size(network.mpc.branch)[1])
    end
end

function get_edge_pos(e, edge_pos, filtered_branches)
    if typeof(edge_pos.f_bus[1])==Int
        rows = vcat(edge_pos[.&(edge_pos.f_bus.==parse(Int64,e.src), edge_pos.t_bus.==parse(Int64,e.dst)),:],
            edge_pos[.&(edge_pos.f_bus.==parse(Int64,e.dst), edge_pos.t_bus.==parse(Int64,e.src)),:])
    else
        rows = vcat(edge_pos[.&(edge_pos.f_bus.==e.src, edge_pos.t_bus.==e.dst),:],
            edge_pos[.&(edge_pos.f_bus.==e.dst, edge_pos.t_bus.==e.src),:])
    end
    for row in collect(eachrow(rows))
        if !(row.name in filtered_branches[!,:element])
            return row.index 
        end
    end
end


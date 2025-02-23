using Random
using BayesNets
# first import the POMDPs.jl interface
using POMDPs

# POMDPModelTools has tools that help build the MDP definition
using POMDPModelTools
# POMDPPolicies provides functions to help define simple policies
using POMDPPolicies
# POMDPSimulators provide functions for running MDP simulations
using POMDPSimulators

using CrossEntropyMethod
using Distributions
using Parameters
using MCTS
using RiskSimulator
using Distributions
using FileIO

using Distributed
using ProgressMeter

Random.seed!(1234)
#####################################################################################
# Bayes Net representation of the scenario decision making problem
#####################################################################################
scenario_types = [T_HEAD_ON, T_LEFT, STOPPING, CROSSING, MERGING, CROSSWALK];
# scenario_types = [STOPPING];


function get_actions(parent, value)
    if parent === nothing
		return Distributions.Categorical(length(scenario_types))
    elseif parent == :type
        # @show parent, value
		options = get_scenario_options(scenario_types[value])
        range_s_sut = options["s_sut"]
        range_v_sut = options["v_sut"]
        actions = [
            Distributions.Uniform(range_s_sut[1], range_s_sut[2]),
            Distributions.Uniform(range_v_sut[1], range_v_sut[2]) 
                ]
        return product_distribution(actions)
    elseif parent == :sut
        # @show parent, value
		options = get_scenario_options(scenario_types[value])
        range_s_adv = options["s_adv"]
        range_v_adv = options["v_adv"]
        actions = [
            Distributions.Uniform(range_s_adv[1], range_s_adv[2]),
            Distributions.Uniform(range_v_adv[1], range_v_adv[2]) 
                ]
        return product_distribution(actions)
	end
end

function create_bayesnet()
    bn = BayesNet(); 
    push!(bn, StaticCPD(:type, get_actions(nothing, nothing)));
    push!(bn, CategoricalCPD(:sut, [:type], [length(scenario_types)], [get_actions(:type, x) for x in 1:length(scenario_types)]));
    push!(bn, CategoricalCPD(:adv, [:type], [length(scenario_types)], [get_actions(:sut, x) for x in 1:length(scenario_types)]));
    # @show rand(bn)
    return bn
end

bn = create_bayesnet();

# #####################################################################################
# # Cross Entropy from Bayes Net
# #####################################################################################
# # starting sampling distribution
# is_dist_0 = Dict{Symbol, Vector{Sampleable}}(:a => [Categorical(5)], :b => [Normal(0, 1)])

# function l(d, s)
#     a = s[:a][1]
#     b = s[:b][1]
#     -(abs(b)>3)
# end

# # Define the likelihood ratio weighting function
# function w(d, s)
#     a = s[:a][1]
#     b = s[:b][1]
#     exp(logpdf(bn, :a=>a, :b=>b) - logpdf(d, s))
# end

#####################################################################################
# Scenario state and evaluation
#####################################################################################
struct DecisionState 
    type::Any # scenario type
    init_sut::Vector{Any} # Initial conditions SUT
    init_adv::Vector{Any} # Initial conditions Adversary
    done::Bool
end

# initial state constructor
DecisionState() = DecisionState(nothing,[nothing],[nothing], false)

# Define the system to test
system = IntelligentDriverModel()    

# Evaluates a scenario using AST
# Returns: scalar risk if failures were discovered, 0 if not, -10.0 if an error occured during search

function eval_AST(s::DecisionState)
    try
        scenario = get_scenario(scenario_types[s.type]; s_sut=Float64(s.init_sut[1]), s_adv=Float64(s.init_adv[1]), v_sut=Float64(s.init_sut[2]), v_adv=Float64(s.init_adv[2]))
        planner = setup_ast(sut=system, scenario=scenario, nnobs=false, seed=rand(1:100000))
        planner.solver.show_progress = false
        search!(planner)    
        α = 0.2 # risk tolerance
        cvar_wt = [0, 0, 1, 0, 0, 0, 0]  # only compute cvar
        risk = overall_area(planner,weights=cvar_wt, α=α)[1]
        if isnan(risk)
            return 0.0
        end
        return risk
    catch err
        # TODO: Write to log file
        @warn err
        return -10.0
    end
end

#####################################################################################
# Baseline Evaluation
#####################################################################################

function random_baseline()
    tmp_sample = rand(bn)
    # @show tmp_sample
    tmp_s = DecisionState(tmp_sample[:type],tmp_sample[:sut],tmp_sample[:adv], true)
    return (tmp_s, eval_AST(tmp_s))
    # return (tmp_s, nothing)
end

results = []
@showprogress @distributed for i=1:1000
    push!(results, random_baseline())
end

states = [result[1] for result in results];
risks = [result[2] for result in results];
save(raw"data\\risks_1000_ALL.jld2", Dict("risks:" => risks, "states:" => states))
#####################################################################################
# MDP definition from Bayes Net
#####################################################################################

# The scenario decision mdp type
mutable struct ScenarioSearch <: MDP{DecisionState, Any}
    discount_factor::Float64 # disocunt factor
    cvars::Vector
end

mdp = ScenarioSearch(1, [])

function POMDPs.reward(mdp::ScenarioSearch, state::DecisionState, action)
    if state.type===nothing || state.init_sut[1]===nothing || state.init_adv[1]===nothing
        r = 0
    else
        r = eval_AST(state)
        push!(mdp.cvars, r)
        # r = sum(state.init_cond)
    end
    return r
end

function POMDPs.initialstate(mdp::ScenarioSearch) # rng unused.
    return DecisionState()
end

# Base.convert(::Type{Int64}, x) = x
# convert(::Type{Union{Float64, Nothing}}, x) = x

function POMDPs.gen(m::ScenarioSearch, s::DecisionState, a, rng)
    # transition model
    if s.type === nothing
        sp = DecisionState(a, [nothing], [nothing], false)
    elseif s.init_sut[1] === nothing
        sp =  DecisionState(s.type, a, [nothing], false)
    elseif s.init_adv[1] === nothing
        sp =  DecisionState(s.type, s.init_sut, a, false)
    else
        sp = DecisionState(s.type, s.init_sut, s.init_adv, true)
    end
    r = POMDPs.reward(m, s, a)
    return (sp=sp, r=r)
end

function POMDPs.isterminal(mdp::ScenarioSearch, s::DecisionState)
    return s.done
end

POMDPs.discount(mdp::ScenarioSearch) = mdp.discount_factor

function POMDPs.actions(mdp::ScenarioSearch, s::DecisionState)
    if s.type===nothing
        return get_actions(nothing, nothing)
    elseif s.init_sut[1] === nothing
        return get_actions(:type, s.type)
    elseif s.init_adv[1] === nothing
        return get_actions(:sut, s.type)
    else
        return Distributions.Uniform(0, 1)   # TODO: Replace with a better placeholder
    end
end

function POMDPs.action(policy::RandomPolicy, s::DecisionState)
    if s.type===nothing
        return rand(get_actions(nothing, nothing))
    elseif s.init_sut[1] === nothing
        return rand(get_actions(:type, s.type))
    elseif s.init_adv[1] === nothing
        return rand(get_actions(:sut, s.type))
    else
        return nothing
    end
end

function rollout(mdp::ScenarioSearch, s::DecisionState, d::Int64)
    if d == 0 || isterminal(mdp, s)
        return 0.0
    else
        a = rand(POMDPs.actions(mdp, s))

        (sp, r) = @gen(:sp, :r)(mdp, s, a, Random.GLOBAL_RNG)
        q_value = r + discount(mdp)*rollout(mdp, sp, d-1)

        return q_value
    end
end

solver = MCTS.DPWSolver(;   estimate_value=rollout, # required.
                            exploration_constant=0.3,
                            n_iterations=1000,
                            enable_state_pw=false, # required.
                            show_progress=true,
                            tree_in_info=true)

planner = solve(solver, mdp)

# a = action(planner, DecisionState())

function MCTS.node_tag(s::DecisionState) 
    if s.done
        return "done"
    else
        return "[$(s.type),$(s.init_sut),$(s.init_adv)]"
    end
end

MCTS.node_tag(a::Union{Int64, Float64, Nothing}) = "[$a]"

using D3Trees

a, info = action_info(planner, DecisionState(), tree_in_info=true)
t = D3Tree(info[:tree], init_expand=1);
inchrome(t)

save(raw"data\\mctsrisks_100_ALL.jld2", Dict("risks:" => planner.mdp.cvars, "states:" => []))

sim = RolloutSimulator()
simulate(sim, mdp, RandomPolicy(mdp))
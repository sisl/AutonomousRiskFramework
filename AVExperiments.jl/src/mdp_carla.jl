using Reexport
@reexport using Distributions
@reexport using PyCall
@reexport using OrderedCollections
using Distributed
using Infiltrator
using LinearAlgebra
using POMDPGym
import POMDPModelTools: Deterministic
using POMDPPolicies
using POMDPs
using Parameters
pyimport("adv_carla")

function pyreload()
    py"""
    import gym
    env_dict = gym.envs.registration.registry.env_specs.copy()
    for env in env_dict:
        if 'adv-carla' in env:
            print("Remove {} from registry".format(env))
            del gym.envs.registration.registry.env_specs[env]
    """
    sys = pyimport("sys")
    for env in filter(k->contains(k, "adv_carla"), keys(sys.modules))
        println("Reloaded $env")
        pyimport("importlib")."reload"(pyimport(env))
    end
end

include("generic_discrete_nonparametric.jl")
include("solvers.jl")
include("task.jl")
include("agents.jl")

##################################################
# Weather and time of day
##################################################

@with_kw mutable struct Weather
    cloudiness             = Uniform(0,100)
    precipitation          = Uniform(0,100)
    sun_altitude_angle     = Uniform(-90,90)
    fog_density            = Uniform(0,100)
end


"""
Fill in default and associative weather parameters for CARLA.
"""
function fill_out_weather!(weather)
    weather[:precipitation_deposits] = weather[:precipitation] # one-to-one "precipitation" with "precipitation deposits"
    weather[:wetness] = weather[:precipitation] # one-to-one "precipitation" with "wetness"
    weather[:fog_distance] = 3.0 # meters
    weather[:wind_intensity] = 0.0 # not useful
    weather[:sun_azimuth_angle] = 180.0 # fixed default
    return weather
end


function Base.rand(rng::AbstractRNG, obj::Weather)
    samples = Dict()
    for name in propertynames(obj)
        distr = getfield(obj, name)
        samples[name] = rand(distr)
    end
    return samples
end

function discretize!(obj, bins)
    for name in propertynames(obj)
        distr = getfield(obj, name)
        if isa(distr, Uniform)
            vals = collect(range(distr.a, stop=distr.b, length=bins))
            probs = normalize(ones(bins), 1)
            discrete_distr = GenericDiscreteNonParametric(vals, probs)
            setfield!(obj, name, discrete_distr)
        else
            error("Can only discretize uniform distributions.")
        end
    end
    return obj
end

function initialize_weather_dict()
    return Dict{Symbol, Any}(map(p->p=>nothing, propertynames(Weather())))
end


##################################################
# Scenario type
##################################################

"""
Only include scenario types that have another agent in the scene (car or pedestrian)
https://carla-scenariorunner.readthedocs.io/en/latest/list_of_scenarios/
"""
SCENARIO_CLASS_MAPPING = Dict(
    # "Scenario1" => "ControlLoss",
    "Scenario2" => "FollowLeadingVehicle",
    "Scenario3" => "DynamicObjectCrossing",
    "Scenario4" => "VehicleTurningRoute",
    "Scenario5" => "OtherLeadingVehicle",
    # "Scenario6" => "ManeuverOppositeDirection", # NOTE: See "test_scenario6_error.{json/xml}"
    # "Scenario7" => "SignalJunctionCrossingRoute",
    # "Scenario8" => "SignalJunctionCrossingRoute",
    # "Scenario9" => "SignalJunctionCrossingRoute",
    # "Scenario10" => "NoSignalJunctionCrossingRoute",
)

function create_scenario_type_distribution()
    vals = keys(SCENARIO_CLASS_MAPPING)
    probs = normalize(ones(length(vals)), 1)
    return GenericDiscreteNonParametric(vals, probs)
end


##################################################
# Other agent type
##################################################

function create_other_actor_type_distribution(scenario_type)
    if scenario_type in ["Scenario2", "Scenario5"]
        car = "vehicle.audi.tt"
        motorcycle = "vehicle.kawasaki.ninja"
        vals = [car, motorcycle]
    elseif scenario_type in ["Scenario3", "Scenario4"]
        bicycle = "vehicle.diamondback.century"
        pedestrian = "walker.pedestrian.0001"
        vals = [bicycle, pedestrian]
    else
        error("No `other_actor_type` for scenario type $scenario_type")
    end
    probs = normalize(ones(length(vals)), 1)
    return GenericDiscreteNonParametric(vals, probs)
end


##################################################
# CARLA scenario selection MDP
##################################################

@with_kw mutable struct ScenarioState
    scenario_type::Union{Nothing, String} = nothing
    other_actor_type::Union{Nothing, String} = nothing
    weather::Union{Nothing, Dict} = nothing
end

Base.hash(s::ScenarioState, h::UInt) = hash((s.scenario_type, s.other_actor_type, s.weather), h)
Base.isequal(s1::ScenarioState, s2::ScenarioState) = (s1.scenario_type == s2.scenario_type) && (s1.other_actor_type == s2.other_actor_type) && (s1.weather == s2.weather)
Base.:(==)(s1::ScenarioState, s2::ScenarioState) = isequal(s1, s2)

const ScenarioAction = Any


@with_kw mutable struct CARLAScenarioMDP <: MDP{ScenarioState, ScenarioAction}
    seed::Int = 0xC0FFEE
    γ::Real = 1.0
    α::Real = 0.01 # probability risk threshold
    scenario_type_distr = create_scenario_type_distribution()
    other_actor_type_distr = create_other_actor_type_distribution # conditional
    weather_bins = 4
    weather_distr = discretize!(Weather(), weather_bins)
    final_state = nothing
    counter::Int = 0
    leaf_noise::Bool = true # indicate whether to apply sequential noise at the leaf nodes (`false` will simply run scenario without noise)
    collect_data::Bool = true
    datasets::Vector = []
    agent::Agent = NEAT
    apply_gnss_noise::Bool = (agent == GNSS)
    sensor_config_gnss::OrderedDict = OrderedDict(
        "id" => "GPS",
        "lat" => Dict("mean" => 0, "std" => 0.0001, "upper" => 0.000000001, "lower" => -0.000000001),
        "lon" => Dict("mean" => 0, "std" => 0.0001, "upper" => 0.000000001, "lower" => -0.000000001),
        "alt" => Dict("mean" => 0, "std" => 0.00000001, "upper" => 0.0000001, "lower" => 0))
    sensor_config_camera::OrderedDict = OrderedDict(
        "id" => "rgb",
        "dynamic_noise_std" => Dict("mean" => 0, "std" => 0.001, "upper" => 1, "lower" => 0),
        "exposure_compensation" => Dict("mean" => 0, "std" => 0.5, "upper" => 1, "lower" => -1))
    run_solver::Function = run_mc_solver
    run_separate_process::Bool = true # Launch CARLA bridge in separate process (to isolate CARLA memory leak)
    render_carla::Bool = true # Show CARLA rendering.
    iterations_per_process::Int = 3 # Number of runs to make in separate Julia process (due to CARLA memory leak).
    scenarios = [] # Collection of specific scenarios sampled and ran.
end


function Base.merge(mdp1::CARLAScenarioMDP, mdp2::CARLAScenarioMDP)
    mdp = deepcopy(mdp1)
    mdp.datasets = vcat(mdp.datasets, mdp2.datasets)
    mdp.scenarios = vcat(mdp.scenarios, mdp2.scenarios)
    return mdp
end


# Counter to monitor when to restart a new Julia process every X iterations
global ITERATIONS_PER_PROCESS_COUNTER = 0


function eval_carla_task!(mdp::CARLAScenarioMDP, s::ScenarioState; kwargs...)
    global ITERATIONS_PER_PROCESS_COUNTER

    run_solver = mdp.run_solver
    seed = mdp.seed + mdp.counter
    scenario_type = s.scenario_type
    other_actor_type = s.other_actor_type
    weather = fill_out_weather!(s.weather)

    Random.seed!(seed)

    if mdp.run_separate_process
        println()
        if nprocs() <= 1
            procid = first(addprocs(1; topology=:master_worker))
            println("Spawning Julia process with id $procid")
        else
            procid = last(procs())
            println("Reusing Julia process id $procid ($ITERATIONS_PER_PROCESS_COUNTER/$(mdp.iterations_per_process))")
        end
        @everywhere eval(quote include(joinpath(@__DIR__, "task.jl")) end)
        @everywhere eval(quote using AVExperiments end)
        task = remotecall_wait(eval_carla_task_core, procid, run_solver, seed, scenario_type, other_actor_type, weather; kwargs...)
        cost, dataset = fetch(task)
    else
        cost, dataset = eval_carla_task_core(run_solver, seed, scenario_type, other_actor_type, weather; kwargs...)
    end

    if mdp.collect_data
        push!(mdp.scenarios, (seed=seed, state=s))
        push!(mdp.datasets, dataset)
    end

    ITERATIONS_PER_PROCESS_COUNTER += 1
    if ITERATIONS_PER_PROCESS_COUNTER >= mdp.iterations_per_process
        println("Removing Julia process id $procid")
        rmprocs(procid)
        ITERATIONS_PER_PROCESS_COUNTER = 0
    end

    mdp.counter += 1

    return cost
end


function eval_carla_single(mdp::CARLAScenarioMDP, s::ScenarioState)
    sensors = [mdp.sensor_config_gnss]
    scenario_type = s.scenario_type
    other_actor_type = s.other_actor_type
    weather = fill_out_weather!(s.weather)

    @info scenario_type
    @info other_actor_type
    display(weather)

    carla_mdp = GymPOMDP(Symbol("adv-carla"), sensors=sensors, seed=mdp.seed, scenario_type=scenario_type, other_actor_type=other_actor_type, weather=weather, no_rendering=false)
    env = carla_mdp.env
    σ = 0.0001 # noise variance
    local info
    while !env.done
        action = σ*rand(3) # TODO: replace with some policy?
        reward, obs, info = POMDPGym.step!(env, action)
        render(env)
    end
    close(env)
    display(info)
    cost = info["cost"]
    return cost
end


function POMDPs.reward(mdp::CARLAScenarioMDP, s::ScenarioState, a::ScenarioAction=nothing)
    if isterminal(mdp, s)
        cost = eval_carla_task!(mdp, s; leaf_noise=mdp.leaf_noise,
                                agent=mdp.agent, apply_gnss_noise=mdp.apply_gnss_noise,
                                sensor_config_gnss=mdp.sensor_config_gnss, sensor_config_camera=mdp.sensor_config_camera,
                                no_rendering=!mdp.render_carla)
        return cost
    else
        return 0
    end
end


function POMDPs.initialstate(mdp::CARLAScenarioMDP)
    return Deterministic(ScenarioState())
end


function POMDPs.gen(mdp::CARLAScenarioMDP, s::ScenarioState, a::ScenarioAction, rng=Random.GLOBAL_RNG)
    if isnothing(s.scenario_type)
        sp = ScenarioState(a, nothing, nothing)
    elseif isnothing(s.other_actor_type)
        sp = ScenarioState(s.scenario_type, a, nothing)
    elseif isnothing(s.weather)
        sp = ScenarioState(s.scenario_type, s.other_actor_type, initialize_weather_dict())
        return gen(mdp, sp, a, rng)
    else
        for k in keys(s.weather)
            if isnothing(s.weather[k])
                sp = ScenarioState(s.scenario_type, s.other_actor_type, copy(s.weather))
                sp.weather[k] = a
                break
            end
        end
    end
    r = reward(mdp, sp, a)
    return (sp=sp, r=r)
end


function POMDPs.isterminal(mdp::CARLAScenarioMDP, s::ScenarioState)
    # terminate when all decisions have been made
    scenario_type_selected = !isnothing(s.scenario_type)
    other_actor_type_selected = !isnothing(s.other_actor_type)
    weather_selected = !isnothing(s.weather) && all(.!isnothing.(values(s.weather)))
    return scenario_type_selected && other_actor_type_selected && weather_selected
end


POMDPs.discount(mdp::CARLAScenarioMDP) = mdp.γ


function POMDPs.actions(mdp::CARLAScenarioMDP, s::ScenarioState)
    if isnothing(s.scenario_type)
        return mdp.scenario_type_distr
    elseif isnothing(s.other_actor_type)
        return mdp.other_actor_type_distr(s.scenario_type) # conditional
    elseif isnothing(s.weather)
        s.weather = initialize_weather_dict()
        return actions(mdp, s)
    else
        for k in keys(s.weather)
            if isnothing(s.weather[k])
                return getfield(mdp.weather_distr, k)
            end
        end
    end
    return []
end


##################################################
# Random policy and rollout
##################################################

function POMDPs.action(policy::RandomPolicy, s::ScenarioState)
    mdp = policy.problem
    return rand(actions(mdp, s))
end


function rollout(mdp::CARLAScenarioMDP, s::ScenarioState)
    if isterminal(mdp, s)
        mdp.final_state = s
        return 0
    else
        policy = RandomPolicy(mdp)
        a = action(policy, s)
        (sp, r) = @gen(:sp, :r)(mdp, s, a)
        q = r + discount(mdp)*rollout(mdp, sp)
        return q
    end
end


##################################################
# Example MDP
##################################################
function run_baseline(iters=10)
    mdp = CARLAScenarioMDP()
    Random.seed!(mdp.seed) # Determinism
    Q = []
    for i in 1:iters
        @info "Random rollout iteration $i"
        s0 = rand(initialstate(mdp))
        q = rollout(mdp, s0)
        push!(Q, q)
    end
    return Q
end

#=
policy = RandomPolicy(mdp)

a0 = action(policy, s0)
s1, r1 = @gen(:sp, :r)(mdp, s0, a0)

a1 = action(policy, s1)
s2, r2 = @gen(:sp, :r)(mdp, s1, a1)

a2 = action(policy, s2)
s3, r3 = @gen(:sp, :r)(mdp, s2, a2)
=#

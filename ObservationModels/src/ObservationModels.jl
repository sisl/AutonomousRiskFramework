module ObservationModels
    using Distributions
    using Parameters
    using Random
    using LinearAlgebra
    using Statistics
    using AdversarialDriving
    using Distributed
    using AutomotiveSimulator

    export Landmark, SensorObservation
    include("structs.jl")

    export Satellite, GPSRangeMeasurement, measure_gps, GPS_fix
    include("gps.jl")

    export INormal_Uniform, INormal_GMM

    include(joinpath("distributions", "inormal_uniform.jl"))
    include(joinpath("distributions", "inormal_gmm.jl"))

    export DistParams, gps_distribution_estimate, traj_logprob
    include("estimate.jl")
end
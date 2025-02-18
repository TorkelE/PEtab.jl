module CatalystExtension

using SciMLBase
using DataFrames
using CSV
using RuntimeGeneratedFunctions
using PEtab
using Printf
using DiffEqCallbacks
using Catalyst

import PEtab.get_obs_sd_parameter

RuntimeGeneratedFunctions.init(@__MODULE__)

# For Optimization and model selection
include(joinpath(@__DIR__, "CatalystExtension", "Create_PEtab_model.jl"))

end
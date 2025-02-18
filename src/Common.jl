# Functions used by both the ODE-solvers and PeTab importer.


"""
    set_parameters_to_file_values!(parameter_map, state_map, parameters_info::ParamData)

Function that sets the parameter and state values in parameter_map and state_map
to those in the PeTab parameters file.

Used when setting up the PeTab cost function, and when solving the ODE-system
for the values in the parameters-file.
"""
function set_parameters_to_file_values!(parameter_map, state_map, parameters_info::ParametersInfo)

    parameter_names = string.(parameters_info.parameter_id)
    parameter_names_str = string.([parameter_map[i].first for i in eachindex(parameter_map)])
    state_namesStr = replace.(string.([state_map[i].first for i in eachindex(state_map)]), "(t)" => "")
    for i in eachindex(parameter_names)

        parameter_name = parameter_names[i]
        valChangeTo = parameters_info.nominal_value[i]

        # Check for value to change to in parameter file
        i_param = findfirst(x -> x == parameter_name, parameter_names_str)
        i_state = findfirst(x -> x == parameter_name, state_namesStr)

        if !isnothing(i_param)
            parameter_map[i_param] = Pair(parameter_map[i_param].first, valChangeTo)
        elseif !isnothing(i_state)
            state_map[i_state] = Pair(state_map[i_state].first, valChangeTo)
        end
    end
end


function splitθ(θ_est::AbstractVector{T},
                θ_indices::ParameterIndices)::Tuple{AbstractVector{T}, AbstractVector{T}, AbstractVector{T}, AbstractVector{T}} where T

    θ_dynamic = @view θ_est[θ_indices.iθ_dynamic]
    θ_observable = @view θ_est[θ_indices.iθ_observable]
    θ_sd = @view θ_est[θ_indices.iθ_sd]
    θ_non_dynamic = @view θ_est[θ_indices.iθ_non_dynamic]

    return θ_dynamic, θ_observable, θ_sd,  θ_non_dynamic
end


function splitθ!(θ_est::AbstractVector,
                 θ_indices::ParameterIndices,
                 petab_ODE_cache::PEtabODEProblemCache)

    @views petab_ODE_cache.θ_dynamic .= θ_est[θ_indices.iθ_dynamic]
    @views petab_ODE_cache.θ_observable .= θ_est[θ_indices.iθ_observable]
    @views petab_ODE_cache.θ_sd .= θ_est[θ_indices.iθ_sd]
    @views petab_ODE_cache.θ_non_dynamic .= θ_est[θ_indices.iθ_non_dynamic]
end


function computeσ(u::AbstractVector,
                  t::Float64,
                  θ_dynamic::AbstractVector,
                  θ_sd::AbstractVector,
                  θ_non_dynamic::AbstractVector,
                  petab_model::PEtabModel,
                  i_measurement::Int64,
                  measurement_info::MeasurementsInfo,
                  θ_indices::ParameterIndices,
                  parameter_info::ParametersInfo)::Real

    # Compute associated SD-value or extract said number if it is known
    mapθ_sd = θ_indices.mapθ_sd[i_measurement]
    if mapθ_sd.is_single_constant == true
        σ = mapθ_sd.constant_values[1]
    else
        σ = petab_model.compute_σ(u, t, θ_sd, θ_dynamic,  θ_non_dynamic, parameter_info, measurement_info.observable_id[i_measurement], mapθ_sd)
    end

    return σ
end


# Compute observation function h
function computehT(u::AbstractVector,
                   t::Float64,
                   θ_dynamic::AbstractVector,
                   θ_observable::AbstractVector,
                   θ_non_dynamic::AbstractVector,
                   petab_model::PEtabModel,
                   i_measurement::Int64,
                   measurement_info::MeasurementsInfo,
                   θ_indices::ParameterIndices,
                   parameter_info::ParametersInfo)::Real

    mapθ_observable = θ_indices.mapθ_observable[i_measurement]
    h = petab_model.compute_h(u, t, θ_dynamic, θ_observable,  θ_non_dynamic, parameter_info, measurement_info.observable_id[i_measurement], mapθ_observable)
    # Transform y_model is necessary
    hT = transform_measurement_or_h(h, measurement_info.measurement_transformation[i_measurement])

    return hT
end


function computeh(u::AbstractVector{T},
                  t::Float64,
                  θ_dynamic::AbstractVector,
                  θ_observable::AbstractVector,
                  θ_non_dynamic::AbstractVector,
                  petab_model::PEtabModel,
                  i_measurement::Int64,
                  measurement_info::MeasurementsInfo,
                  θ_indices::ParameterIndices,
                  parameter_info::ParametersInfo)::Real where T

    mapθ_observable = θ_indices.mapθ_observable[i_measurement]
    h = petab_model.compute_h(u, t, θ_dynamic, θ_observable,  θ_non_dynamic, parameter_info, measurement_info.observable_id[i_measurement], mapθ_observable)
    return h
end



"""
    transform_measurement_or_h(val::Real, transformationArr::Array{Symbol, 1})

    Transform val using either :lin (identify), :log10 and :log transforamtions.
"""
function transform_measurement_or_h(val::T, transform::Symbol)::T where T
    if transform == :lin
        return val
    elseif transform == :log10
        return val > 0 ? log10(val) : Inf
    elseif transform == :log
        return val > 0 ? log(val) : Inf
    else
        println("Error : $transform is not an allowed transformation")
        println("Only :lin, :log10 and :log are supported.")
    end
end


# Function to extract observable or noise parameters when computing h or σ
function get_obs_sd_parameter(θ::AbstractVector, parameter_map::θObsOrSdParameterMap)

    # Helper function to map SD or obs-parameters in non-mutating way
    function map1Tmp(i_value)
        whichI = sum(parameter_map.should_estimate[1:i_value])
        return parameter_map.index_in_θ[whichI]
    end
    function map2Tmp(i_value)
        whichI = sum(.!parameter_map.should_estimate[1:i_value])
        return whichI
    end

    # In case of no SD/observable parameter exit function
    if parameter_map.n_parameters == 0
        return
    end

    # In case of single-value return do not have to return an array and think about type
    if parameter_map.n_parameters == 1
        if parameter_map.should_estimate[1] == true
            return θ[parameter_map.index_in_θ][1]
        else
            return parameter_map.constant_values[1]
        end
    end

    n_parameters_estimate = sum(parameter_map.should_estimate)
    if n_parameters_estimate == parameter_map.n_parameters
        return θ[parameter_map.index_in_θ]

    elseif n_parameters_estimate == 0
        return parameter_map.constant_values

    # Computaionally most demanding case. Here a subset of the parameters
    # are to be estimated. This code must be non-mutating to support Zygote which
    # negatively affects performance
    elseif n_parameters_estimate > 0
        _values = [parameter_map.should_estimate[i] == true ? θ[map1Tmp(i)] : 0.0 for i in 1:parameter_map.n_parameters]
        values = [parameter_map.should_estimate[i] == false ? parameter_map.constant_values[map2Tmp(i)] : _values[i] for i in 1:parameter_map.n_parameters]
        return values
    end
end


# Transform parameter from log10 scale to normal scale, or reverse transform
function transformθ!(θ::AbstractVector,
                     n_parameters_estimate::Vector{Symbol},
                     θ_indices::ParameterIndices;
                     reverse_transform::Bool=false)

    @inbounds for (i, θ_name) in pairs(n_parameters_estimate)
        θ[i] = transform_θ_element(θ[i], θ_indices.θ_scale[θ_name], reverse_transform=reverse_transform)
    end
end

# Transform parameter from log10 scale to normal scale, or reverse transform
function transformθ(θ::AbstractVector,
                    n_parameters_estimate::Vector{Symbol},
                    θ_indices::ParameterIndices;
                    reverse_transform::Bool=false)::AbstractVector

    if isempty(θ)
        return similar(θ)
    else
        out = [transform_θ_element(θ[i], θ_indices.θ_scale[θ_name], reverse_transform=reverse_transform) for (i, θ_name) in pairs(n_parameters_estimate)]
        return out
    end
end
function transformθ(θ::AbstractVector{T},
                    n_parameters_estimate::Vector{Symbol},
                    θ_indices::ParameterIndices,
                    whichθ::Symbol,
                    petab_ODE_cache::PEtabODEProblemCache;
                    reverse_transform::Bool=false)::AbstractVector{T} where T

    if whichθ === :θ_dynamic
        θ_out = get_tmp(petab_ODE_cache.θ_dynamicT, θ)
    elseif whichθ === :θ_sd
        θ_out = get_tmp(petab_ODE_cache.θ_sdT, θ)
    elseif whichθ === :θ_non_dynamic
        θ_out = get_tmp(petab_ODE_cache.θ_non_dynamicT, θ)
    elseif whichθ === :θ_observable
        θ_out = get_tmp(petab_ODE_cache.θ_observableT, θ)
    end

    @inbounds for (i, θ_name) in pairs(n_parameters_estimate)
        θ_out[i] = transform_θ_element(θ[i], θ_indices.θ_scale[θ_name], reverse_transform=reverse_transform)
    end

    return θ_out
end


function transform_θ_element(θ_element,
                           scale::Symbol;
                           reverse_transform::Bool=false)::Real

    if scale === :lin
        return θ_element
    elseif scale === :log10
        return reverse_transform == true ? log10(θ_element) : exp10(θ_element)
    elseif scale === :log
        return reverse_transform == true ? log(θ_element) : exp(θ_element)
    end
end


function change_ode_parameters!(p_ode_problem::AbstractVector,
                                u0::AbstractVector,
                                θ::AbstractVector,
                                θ_indices::ParameterIndices,
                                petab_model::PEtabModel)

    map_ode_problem = θ_indices.map_ode_problem
    p_ode_problem[map_ode_problem.i_ode_problem_θ_dynamic] .= θ[map_ode_problem.iθ_dynamic]
    petab_model.compute_u0!(u0, p_ode_problem)

    return nothing
end


function change_ode_parameters(p_ode_problem::AbstractVector,
                               θ::AbstractVector,
                               θ_indices::ParameterIndices,
                               petab_model::PEtabModel)

    # Helper function to not-inplace map parameters
    function mapParamToEst(j::Integer, mapDynParam::Map_ode_problem)
        which_index = findfirst(x -> x == j, mapDynParam.i_ode_problem_θ_dynamic)
        return map_ode_problem.iθ_dynamic[which_index]
    end

    map_ode_problem = θ_indices.map_ode_problem
    outp_ode_problem = [i ∈ map_ode_problem.i_ode_problem_θ_dynamic ? θ[mapParamToEst(i, map_ode_problem)] : p_ode_problem[i] for i in eachindex(p_ode_problem)]
    outu0 = petab_model.compute_u0(outp_ode_problem)

    return outp_ode_problem, outu0
end


"""
    dual_to_float(x::ForwardDiff.Dual)::Real

Via recursion convert a Dual to a Float.
"""
function dual_to_float(x::ForwardDiff.Dual)::Real
    return dual_to_float(x.value)
end
"""
    dual_to_float(x::AbstractFloat)::AbstractFloat
"""
function dual_to_float(x::AbstractFloat)::AbstractFloat
    return x
end

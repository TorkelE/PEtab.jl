function parse_SBML_reactions!(model_dict::Dict, model_SBML::SBML.Model)::Nothing

    for (id, reaction) in model_SBML.reactions
        # Process kinetic math into Julia syntax 
        _formula = parse_SBML_math(reaction.kinetic_math)
               
        # Add values for potential kinetic parameters (where-statements)
        for (parameter_id, parameter) in reaction.kinetic_parameters
            _formula = replace_variable(_formula, parameter_id, string(parameter.value))
        end

        # Replace SBML functions, rescale species properly etc...
        formula = process_SBML_str_formula(_formula, model_dict, model_SBML, check_scaling=true)
        reactants = Vector{String}(undef, length(reaction.reactants))
        reactants_stoichiometry = similar(reactants)
        products = Vector{String}(undef, length(reaction.products))
        products_stoichiometry = similar(products)
        
        for (i, reactant) in pairs(reaction.reactants)
            push!(model_dict["appear_in_reactions"], reactant.species)
            if model_dict["species"][reactant.species].boundary_condition == true
                continue
            end
            stoichiometry = parse_stoichiometry(reactant, model_dict)
            compartment_scaling = get_compartment_scaling(reactant.species, formula, model_dict)
            model_dict["species"][reactant.species].formula *= " - " * stoichiometry * compartment_scaling * "(" * formula * ")"

            reactants[i] = reactant.species
            reactants_stoichiometry[i] = stoichiometry
        end

        for (i, product) in pairs(reaction.products)
            push!(model_dict["appear_in_reactions"], product.species)
            if model_dict["species"][product.species].boundary_condition == true
                continue
            end
            stoichiometry = parse_stoichiometry(product, model_dict)
            compartment_scaling = get_compartment_scaling(product.species, formula, model_dict)
            model_dict["species"][product.species].formula *= " + " * stoichiometry * compartment_scaling * "(" * formula * ")"

            products[i] = product.species
            products_stoichiometry[i] = stoichiometry
        end

        model_dict["reactions"][id] = ReactionSBML(id, formula, products, products_stoichiometry, reactants, reactants_stoichiometry)
    end

    # Species given via assignment rules, or initial assignments which only affect stoichiometry
    # are species that should not be included down the line in the model, hence they are 
    # here removed from the model 
    remove_stoichiometry_math_from_species!(model_dict, model_SBML)
end


function get_compartment_scaling(specie::String, formula::String, model_dict::Dict)::String

    # The case of the specie likelly being given via an algebraic rule
    if isempty(formula)
        return "*"
    end

    if model_dict["species"][specie].only_substance_units == true
        return "*"
    end

    if model_dict["species"][specie].unit == :Amount
        return "*"
    end

    if model_dict["species"][specie].unit == :Concentration
        return "/" * model_dict["species"][specie].compartment * "*"
    end
end



function parse_stoichiometry(specie_reference::SBML.SpeciesReference, model_dict::Dict)::String

    if !isnothing(specie_reference.id)
        
        if specie_reference.id ∈ keys(model_dict["generated_ids"])
            stoichiometry = model_dict["generated_ids"][specie_reference.id]
            return stoichiometry

        # Two following special cases where the stoichiometry is given by another variable in the model             
        elseif specie_reference.id ∈ model_dict["rate_rule_variables"]
            return specie_reference.id

        elseif !isempty(model_dict["events"]) && any(occursin.(specie_reference.id, reduce(vcat, [e.formulas for e in values(model_dict["events"])])))
            return specie_reference.id
        end
        
        stoichiometry = specie_reference.id
        # Here the stoichiometry is given as an assignment rule which has been interpreted as an additional model specie, 
        # so the value is taken from the initial value
        if stoichiometry ∈ keys(model_dict["species"]) 
            stoichiometry = model_dict["species"][stoichiometry].initial_value
            if is_number(stoichiometry)
                stoichiometry = isnothing(stoichiometry) || stoichiometry == "nothing" ? "1.0" : stoichiometry
            end
            # Can be nested 1 level 
            if stoichiometry ∈ keys(model_dict["species"]) && model_dict["species"][stoichiometry].assignment_rule == true
                stoichiometry = model_dict["species"][stoichiometry].initial_value
            end

            return stoichiometry
        end

        # Last case where stoichiometry is not referenced anywhere in the model assignments, rules etc..., assign 
        # to default value
        stoichiometry = string(specie_reference.stoichiometry)

    else
        stoichiometry = isnothing(specie_reference.stoichiometry) ? "1" : string(specie_reference.stoichiometry)
        stoichiometry = stoichiometry[1] == '-' ? "(" * stoichiometry * ")" : stoichiometry
    end

    return isnothing(stoichiometry) || stoichiometry == "nothing" ? "1.0" : stoichiometry
end


function remove_stoichiometry_math_from_species!(model_dict::Dict, model_SBML::SBML.Model)::Nothing

    for (id, reaction) in model_SBML.reactions
        specie_references = vcat([reactant for reactant in reaction.reactants], [product for product in reaction.products])
        for specie_reference in specie_references

            if specie_reference.id ∈ keys(model_dict["generated_ids"]) || isnothing(specie_reference.id)
                continue
            end

            if specie_reference.id ∈ model_dict["rate_rule_variables"]
                if specie_reference.id ∈ keys(model_SBML.initial_assignments)
                    continue
                end
                stoichiometry_t0 = isnothing(specie_reference.stoichiometry) ? "1.0" : string(specie_reference.stoichiometry)
                model_dict["species"][specie_reference.id].initial_value = stoichiometry_t0
                continue
            end

            if !isempty(model_dict["events"]) && any(occursin.(specie_reference.id, reduce(vcat, [e.formulas for e in values(model_dict["events"])])))
                continue
            end

            # An artifact from how the stoichiometry is procssed as assignment rule
            # or initial assignment 
            if specie_reference.id ∈ keys(model_dict["species"]) 
                delete!(model_dict["species"], specie_reference.id)
            end
        end
    end
    return nothing
end
# Handles piecewise functions that are to be redefined with ifelse statements in the model
# equations to allow MKT symbolic calculations.
# Calls goToBottomPiecewiseToEvent to handle multiple logical conditions.
function rewrite_piecewise_to_ifelse(rule_formula, variable, model_dict, base_functions, model_SBML; ret_formula::Bool=false)

    piecewise_strs = get_piecewise_str(rule_formula)
    eq_syntax_dict = Dict() # Hold the Julia syntax for iffelse statements

    # If the rule variable is a part of the parameters list remove it
    if variable in keys(model_dict["parameters"])
        delete!(model_dict["parameters"], variable)
    end

    # Loop over each piecewise statement
    for i in eachindex(piecewise_strs)

        piecewise_str = (piecewise_strs[i])[11:end-1] # Extract everything inside piecewise

        args = split_between(piecewise_str, ',')
        vals = args[1:2:end]
        conds = args[2:2:end]

        # In case our variable is the sum of several piecewise bookeep each piecewise
        if length(piecewise_strs) > 1
            variable_change = variable * "Event" * string(i)
        else
            variable_change = variable
        end

        if length(conds) > 1
            println("Warning : Potentially breaking example with multiple conditions")
        end

        # Process the piecewise into ifelse statements
        c_index, condition = 1, conds[1]

        # Check if we have nested piecewise within either the active or inactive value. If true, apply recursion
        # to reach bottom level of piecewise.
        if occursin("piecewise(", vals[c_index])
            value_active = rewrite_piecewise_to_ifelse(vals[c_index], "foo", model_dict, base_functions, model_SBML, ret_formula=true)#[7:end]
            value_active = rewrite_derivatives(value_active, model_dict, base_functions, model_SBML)
        else
            value_active = rewrite_derivatives(vals[c_index], model_dict, base_functions, model_SBML)
        end
        if occursin("piecewise(", vals[end])
            value_inactive = rewrite_piecewise_to_ifelse(vals[end], "foo", model_dict, base_functions, model_SBML, ret_formula=true)#[7:end]
            value_inactive = rewrite_derivatives(value_inactive, model_dict, base_functions, model_SBML)
        else
            value_inactive = rewrite_derivatives(vals[end], model_dict, base_functions, model_SBML)
        end

        if condition[1:2] == "lt" || condition[1:2] == "gt" || condition[1:2] == "eq" || condition[1:3] == "neq" || condition[1:3] == "geq" || condition[1:3] == "leq" 
            eq_syntax_dict[variable_change] = simple_piecewise_to_ifelse(condition, variable_change, value_active, value_inactive, model_dict, base_functions)
        elseif condition[1:3] == "and" || condition[1:2] == "if" || condition[1:2] == "or" || condition[1:3] == "xor" || condition[1:3] == "not"
            eq_syntax_dict[variable_change] = complex_piecewise_to_ifelse(condition, variable, value_active, value_inactive, model_dict, base_functions)
        else
            @error "Somehow we cannot process the piecewise expression"
        end
    end

    # Add the rule as equation into the model
    delete!(model_dict["inputFunctions"], "foo")
    input_str = variable * " ~ "
    formulaUse = deepcopy(rule_formula)
    if length(piecewise_strs) > 1
        for i in eachindex(piecewise_strs)
            formulaUse = replace(formulaUse, piecewise_strs[i] => eq_syntax_dict[variable * "Event" * string(i)])
        end
    else
        formulaUse = replace(formulaUse, piecewise_strs[1] => eq_syntax_dict[variable])
    end
    if ret_formula == false
        model_dict["inputFunctions"][variable] = input_str * rewrite_derivatives(formulaUse, model_dict, base_functions, model_SBML)
        return nothing
    else
        return formulaUse
    end
end


function get_piecewise_str(arg_str::AbstractString)::Array{String, 1}

    # Extract in a string the substrings captured by the piecewise
    i_piecewise = findall("piecewise(", arg_str)
    n_piecewise = length(i_piecewise)
    piecewise_str = fill("", n_piecewise)

    # Extract entire piecewise expression. Handles inner paranthesis, e.g
    # when we have "piecewise(0, lt(t - insulin_time_1, 0), 1)" it extracts
    # the full expression. Also does not extrat nested. Will not extract the innner
    # one for
    # piecewise(beta_0, lt(t, t_1), piecewise(beta_1, lt(t, t_2), beta_2 * (1 - beta_2_multiplier)))
    i, k = 1, 1
    while i <= n_piecewise
        i_start = i_piecewise[i][1]
        n_inner_paranthesis = 0
        i_end = i_piecewise[i][end]
        while true
            i_end += 1
            if n_inner_paranthesis == 0 && arg_str[i_end] == ')'
                break
            end

            if arg_str[i_end] == '('
                n_inner_paranthesis += 1
            end

            if arg_str[i_end] == ')'
                n_inner_paranthesis -= 1
            end
        end

        piecewise_str[k] = arg_str[i_start:i_end]
        k += 1

        # Check the number of piecewise inside the piecewise to avoid counting nested ones
        n_inner_piecewise = length(findall("piecewise(", arg_str[i_start:i_end]))
        i += n_inner_piecewise
    end

    return piecewise_str[piecewise_str .!== ""]
end


function simple_piecewise_to_ifelse(condition, variable, value_active, value_inactive, dicts, base_functions)

    if "leq" == condition[1:3]
        stripped_condition = condition[5:end-1]
        inEqUse = " <= "
    elseif "lt" == condition[1:2]
        stripped_condition = condition[4:end-1]
        inEqUse = " < "
    elseif "geq" == condition[1:3]
        stripped_condition = condition[5:end-1]
        inEqUse = " >= "
    elseif "gt" == condition[1:2]
        stripped_condition = condition[4:end-1]
        inEqUse = " > "
    elseif "eq" == condition[1:2]
        stripped_condition = condition[4:end-1]
        inEqUse = " == "        
    elseif "neq" == condition[1:3]
        stripped_condition = condition[5:end-1]
        inEqUse = " != "  
    elseif "true" == condition[1:4]
        return "true"
    elseif "false" == condition[1:5]
        return "false"
    else
        @error "Cannot recognize form of inequality, condition = $condition"
    end

    parts = split_between(stripped_condition, ',')
    # Trigger of event
    expression = "ifelse(" * parts[1] * inEqUse * parts[2] * ", " * value_active * ", " * value_inactive * ")"

    return expression
end


function complex_piecewise_to_ifelse(condition, variable, value_active, value_inactive, model_dict, base_functions)
    event_str = recursion_complex_piecewise(condition, variable, model_dict, base_functions)
    return event_str * " * (" * value_active * ") + (1 - " * event_str *") * (" * value_inactive * ")"
end


# As MTK does not support iffelse with multiple comparisons, e.g, a < b && c < d when we have nested piecewise
# with && and || statements the situation is more tricky when trying to create a reasonable expression.
function recursion_complex_piecewise(condition, variable, model_dict, base_functions)

    # mutliplication can be used to mimic an and condition for two bool variables
    if "and" == condition[1:3]
        stripped_condition = condition[5:end-1]
        left_part, rigth_part = split_between(stripped_condition, ',')
        left_part_exp = recursion_complex_piecewise(left_part, variable, model_dict, base_functions)
        rigth_part_exp = recursion_complex_piecewise(rigth_part, variable, model_dict, base_functions)

        # An or statment can in a differentiable way here be encoded as sigmoid function
        return "(" * left_part_exp * ") * (" * rigth_part_exp * ")"

    # tanh can be used to approximate an or condition for two bool        
    elseif "if" == condition[1:2] || "or" == condition[1:2]
        stripped_condition = condition[4:end-1]
        left_part, rigth_part = split_between(stripped_condition, ',')
        left_part_exp = recursion_complex_piecewise(left_part, variable, model_dict, base_functions)
        rigth_part_exp = recursion_complex_piecewise(rigth_part, variable, model_dict, base_functions)

        return "tanh(10 * (" * left_part_exp * "+" *  rigth_part_exp * "))"

    elseif "not" == condition[1:3]
        stripped_condition = condition[5:end-1]
        condition = recursion_complex_piecewise(stripped_condition, variable, model_dict, base_functions)
        return "(1 - " * condition * ")"        

    # xor for two boolean variables can be replicated with a second degree polynominal which is zero at 
    # 0 and 2, but 1 at x=1
    elseif "xor" == condition[1:3]
        stripped_condition = condition[5:end-1]
        left_part, rigth_part = split_between(stripped_condition, ',')
        left_part_exp = recursion_complex_piecewise(left_part, variable, model_dict, base_functions)
        rigth_part_exp = recursion_complex_piecewise(rigth_part, variable, model_dict, base_functions)

        return "(-(" * left_part_exp * "+" *  rigth_part_exp * ")^2 + 2*(" * left_part * "+" * rigth_part_exp * "))"

    else
        return simple_piecewise_to_ifelse(condition, variable, "1.0", "0.0", model_dict, base_functions)
    end
end


# Splits strings by a given delimiter, but only if the delimiter is not inside a function / parenthesis.
function split_between(stringToSplit, delimiter)
    parts = Vector{SubString{String}}(undef, length(stringToSplit))
    numParts = 0
    inParenthesis = 0
    startPart = 1
    endPart = 1
    for i in eachindex(stringToSplit)
        if stringToSplit[i] == '('
            inParenthesis += 1
        elseif stringToSplit[i] == ')'
            inParenthesis -= 1
        end
        if stringToSplit[i] == delimiter && inParenthesis == 0
            endPart = i-1
            numParts += 1
            parts[numParts] = stringToSplit[startPart:endPart]
            parts[numParts] = strip(parts[numParts])
            startPart = i+1
        end
    end
    numParts += 1
    parts[numParts] = stringToSplit[startPart:end]
    parts[numParts] = strip(parts[numParts])
    parts = parts[1:numParts]
end


# Check if time is present in a string (used for rewriting piecewise to event)
function check_for_time(str::String)
    str_no_whitespace = replace(str, " " => "")

    # In case we find time t
    iT = 0
    t_present = false
    for i in eachindex(str_no_whitespace)
        if str_no_whitespace[i] == 't'
            if (i > 1 && i < length(str_no_whitespace)) && !isletter(str_no_whitespace[i-1]) && !isletter(str_no_whitespace[i+1])
                t_present = true
                iT = i
                break
            elseif i == 1 && i < length(str_no_whitespace) && !isletter(str_no_whitespace[i+1])
                t_present = true
                iT = i
                break
            elseif i == 1 && i == length(str_no_whitespace)
                t_present = true
                iT = i
                break
            elseif 1 == length(str_no_whitespace)
                t_present = true
                iT = i
                break
            elseif i == length(str_no_whitespace) && length(str_no_whitespace) > 1 && !isletter(str_no_whitespace[i-1])
                t_present = true
                iT = i
                break
            end
        end
    end

    return t_present
end


# If we identity time in an ifelse expression identify the sign of time to know whether or not the ifelse statement will
# or will not be triggered with time. 
# TODO : This code is bad and should be refactored (albeit it works)
function check_sign_time(str::String)

    # Easy special case with single term
    str_no_whitespace = replace(str, " " => "")
    str_no_whitespace = replace(str_no_whitespace, "(" => "")
    str_no_whitespace = replace(str_no_whitespace, ")" => "")
    if str_no_whitespace == "t"
        return 1
    end

    terms = t_presenterms(str_no_whitespace)
    i_time = 0
    for i in eachindex(terms)
        i_start, i_end = terms[i]
        if check_for_time(str_no_whitespace[i_start:i_end]) == true
            i_time = i
            break
        end
    end
    i_start, i_end = terms[i_time]
    time_str = str_no_whitespace[i_start:i_end]
    sign_time = findSignTerm(time_str)
    if i_start == 1
        sign_before = 1
    elseif str_no_whitespace[i_start-1] == '-'
        sign_before = -1
    else
        sign_before = 1
    end

    return sign_time * sign_before
end


# Returns the end index for a paranthesis for a string, assuming that the string starts
# with a paranthesis
function findIParanthesis(str::String)
    numberNested = 0
    i_end = 1
    for i in eachindex(str)
        if str[i] == '('
            numberNested += 1
        end
        if str[i] == ')'
            numberNested -= 1
        end
        if numberNested == 0
            i_end = i
            break
        end
    end
    return i_end
end


# For a mathemathical expression finds the terms
function t_presenterms(str::String)
    iTerm = Array{Tuple, 1}(undef, 0)
    i = 1
    while i < length(str)
        if str[i] == '-' || str[i] == '+' || isletter(str[i]) || isnumeric(str[i]) || str[i] == '('
            i_end = 0
            i_start = str[i] ∈ ['-', '+'] ? i+1 : i
            j = i_start
            while j ≤ length(str)
                if str[j] == '+'
                    i_end = j-1
                    i = j
                    break
                end
                if str[j] == '-'
                    if length(str) ≥ j+1 && (isnumeric(str[j+1]) || isletter(str[j+1]))
                        if j == i_start
                            j += 1
                            continue
                        elseif str[j-1] ∈ ['*', '/']
                            j += 1
                            continue
                        else
                            i_end = j-1
                            i = j
                            break
                        end
                    else
                        i_end = j-1
                        i = j
                        break
                    end
                end
                if str[j] == '('
                    j += (findIParanthesis(str[j:end]) - 1)
                    if j == length(str)
                        i_end = j
                        i = j
                        break
                    end
                end
                j += 1
                if j ≥ length(str)
                    j = length(str)
                    i_end = j
                    i = j
                    break
                end
            end
            iTerm = push!(iTerm, tuple(i_start, i_end))
        end
    end
    return iTerm
end


# For a string like a*b/(c+d) identify sign of the product assuming all variables,
# e.g a, b, c, d... are positive.
function findSignTerm(str::String)
    # Identify each factor
    iFactor = Array{Tuple, 1}(undef, 0)
    i = 1
    while i ≤ length(str)
        i_start = i
        j = i_start
        i_end = 0
        while j ≤ length(str)
            if str[j] ∈ ['*', '/']
                i_end = j - 1
                i = j+1
                break
            end
            if length(str) == j
                i_end = j
                i = j + 1
                break
            end
            if str[j] == '('
                j += (findIParanthesis(str[j:end]) - 1)
                i_end = j
                if length(str) > j+1 && str[j+1] ∈ ['*', '/']
                    i = j+2
                else
                    i = j+1
                end
                break
            end
            j += 1
        end
        iFactor = push!(iFactor, tuple(i_start, i_end))
        if i_end == length(str)
            break
        end
    end

    signTerms = ones(length(iFactor))
    for i in eachindex(iFactor)

        i_start, i_end = iFactor[i]

        if str[i_start] == '('
            signTerms[i] = getSignExpression(str[(i_start+1):(i_end-1)])
        elseif '-' ∈ str[i_start:i_end]
            signTerms[i] = -1
        else
            signTerms[i] = 1
        end
    end
    return prod(signTerms)
end


# Get the sign of a factor like "(a + b * (c + d)*-1) assuming all variables are
# positive. In case we cannot infer the sign Inf is returned. Employs recursion to
# handle paranthesis
function getSignExpression(str::String)

    iTerms = t_presenterms(str)
    signTerms = ones(Float64, length(iTerms)) * 100
    for i in eachindex(signTerms)

        # Get the sign before the term
        i_start, i_end = iTerms[i]
        if i_start == 1
            sign_beforeTerm = 1
        elseif str[i_start-1] == '-'
            sign_beforeTerm = -1
        elseif str[i_start-1] == '+'
            sign_beforeTerm = 1
        else
            println("Cannot infer sign before term")
        end

        valRet = findSignTerm(str[i_start:i_end])
        signTerms[i] = sign_beforeTerm * valRet

    end

    if all(i -> i == 1, signTerms)
        return 1
    elseif all(i -> i == -1, signTerms)
        return -1
    # In case all terms do not have the same sign and we thus cannot solve
    # without doubt the sign.
    else
        return Inf
    end
end

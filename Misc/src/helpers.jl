function queryfromstruct(st::Type; kwargs...)
    local query
    try
        query = st(; kwargs...)
    catch error
        if error isa ArgumentError
            @error "Wrong query parameters for ($(st))."
            rethrow(error)
        end
    end
    fieldnames(typeof(query))
    params = Dict()
    for s in fieldnames(Params)
        f = getproperty(query, s)
        isnothing(f) && continue
        params[s] = string(f)
    end
    query
end

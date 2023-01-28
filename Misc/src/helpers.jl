function queryfromstruct(T::Type, sep=","; kwargs...)
    query = try
        T(; kwargs...)
    catch error
        error isa ArgumentError && @error "Wrong query parameters for ($(st))."
        rethrow(error)
    end
    params = Dict()
    for s in fieldnames(T)
        f = getproperty(query, s)
        isnothing(f) && continue
        ft = typeof(f)
        hasmethod(length, (ft,)) && length(f) == 0 && continue
        params[string(s)] =
            ft != String && hasmethod(iterate, (ft,)) ? join(f, sep) : string(f)
    end
    params
end

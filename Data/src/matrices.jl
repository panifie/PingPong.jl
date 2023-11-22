@doc "Redefines given variable to a Matrix with type of the underlying container type.

$(TYPEDSIGNATURES)
"
macro as_mat(data)
    tp = esc(:type)
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            $d = Matrix{$tp}($d)
        end
    end
end

@doc "Same as `as_mat` but returns the new matrix.

$(TYPEDSIGNATURES)
"
macro to_mat(data, tp=nothing)
    if tp === nothing
        tp = esc(:type)
    else
        tp = esc(tp)
    end
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            Matrix{$tp}($d)
        else
            $d
        end
    end
end

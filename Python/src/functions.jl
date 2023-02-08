function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

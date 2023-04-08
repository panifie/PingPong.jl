using PythonCall: pystr, Py

function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

const pyCached = Dict{String,Py}()
macro pystr(k)
    s = esc(k)
    :($__module__.@lget! $pyCached $s pystr($s))
end

export @pystr

using Serialization
using .Lang

const CHECK_FUNCTIONS = Function[]

# Required by external modules
using DataStructures: DataStructures

@doc """A `stub!` function usually fills a container with readily available data."""
stub!(args...; kwargs...) = error("not implemented")

tobytes(buf::IOBuffer, data) = begin
    @ifdebug @assert position(buf) == 0
    serialize(buf, data)
    take!(buf)
end

@doc """Convert a value data to its byte representation.

$(TYPEDSIGNATURES)

This function converts the input value data to its byte representation.
"""
tobytes(data) = begin
    buf = IOBuffer()
    try
        tobytes(buf, data)
    finally
        close(buf)
    end
end

@doc """Convert a byte array bytes to its original data representation.

$(TYPEDSIGNATURES)

This function converts the input byte array bytes back to its original data representation.
"""
todata(bytes) = begin
    buf = IOBuffer(bytes)
    try
        deserialize(buf)
    finally
        close(buf)
    end
end
todata(buf::IOBuffer, bytes) = begin
    truncate(buf, 0)
    write(buf, bytes)
    seekstart(buf)
    if buf.size > 0
        deserialize(buf)
    end
end

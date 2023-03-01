using Serialization
using Lang

tobytes(buf::IOBuffer, data) = begin
    @ifdebug @assert position(buf) == 0
    serialize(buf, data)
    take!(buf)
end

tobytes(data) = begin
    buf = IOBuffer()
    try
        tobytes(buf, data)
    finally
        close(buf)
    end
end

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
    deserialize(buf)
end

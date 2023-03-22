import Base.display
using Dates: AbstractDateTime

abstract type ContiguityException <: Exception end

struct RightContiguityException <: ContiguityException
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

function show(io::IO, e::RightContiguityException)
    write(io, "Data stored ends at $(e.stored_date) while new data starts at $(e.new_date).")
end

struct LeftContiguityException <: Exception
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

function show(io::IO, e::LeftContiguityException)
    write(io, "Data stored starts at $(e.stored_date) while new data ends at $(e.new_date).")
end
show(e::LeftContiguityException) = display(e)

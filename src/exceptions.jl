struct RightContiguityException <: Exception
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

display(e::RightContiguityException) = "Data stored ends at $(e.stored_date) while new data starts at $(e.new_date)."

struct LeftContiguityException <: Exception
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

display(e::LeftContiguityException) = "Data stored starts at $(e.stored_date) while new data ends at $(e.new_date)."

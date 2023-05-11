import Instruments: freecash
using Instances: Instances as inst

freecash(s::Strategy, ::AssetInstance, ::Nothing) = st.freecash(s)
function freecash(s::Strategy, ai::AssetInstance)
    let pos = position(ai)
        isnothing(pos) ? st.freecash(s) : inst.freecash(ai, inst.posside(pos)())
    end
end
freecash(::Strategy, ai::AssetInstance, p::PositionSide) = inst.freecash(ai, p())

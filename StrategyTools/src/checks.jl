@doc """ Check if collateral is below a calculated threshold

$(TYPEDSIGNATURES)

Determines if the collateral of a position `p` is less than the minimum required amount or a dynamic threshold based on `s[:qt_base]`.
"""
belowtotal(s, ai, p; qt=s.qt_base) = collateral(p) < max(ai.limits.amount.min, current_total(s) * qt)

@doc """ Verify if free cash is above the entry cost minimum

$(TYPEDSIGNATURES)
"""
hasentrycash(s, ai) = freecash(s) > ai.limits.cost.min

@doc """ Assess if amount exceeds the minimum exit amount

$(TYPEDSIGNATURES)
"""
hasexitcash(amt, ai) = amt > ai.limits.amount.min


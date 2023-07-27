using .Instances: AssetInstance
using .Exchanges: is_pair_active
isactive(a::AssetInstance) = is_pair_active(a.asset.raw, a.exchange)

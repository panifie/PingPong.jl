@doc "Global configuration instance."
const config = Config()
const SourcesDict = Dict{Symbol,String}()
const _config_defaults = _defaults(config)
const FUNDING_PERIOD = Hour(8)
@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()
const OFFLINE = Ref(false)

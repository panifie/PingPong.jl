The bot uses a configuration file, located at `user/pingpong.toml` by default. Currently it only stores:
- Minor exchange configurations. The `ExchangeID` symbol is the key that references the exchange config section.
- Strategies. The strategy module name is the section key.
  - `include_file`: The entry file of the strategy
  - `margin`: margin mode to instantiate the strategy with.
  
You shouldn't expect to have to put too many options in the config, as the majority should be specified as constants in the strategy module itself. This avoids unexpected behaviour where a mix of config options and strategy options override each other.

Exchange api keys are stored in separate files with naming `\${ExchangeID}[_sandbox].json`. Api keys for sandbox endpoints are suffixed with `_sandbox`. Exchanges are always instantiated in sandbox mode by default and indeed if the exchange doesn't have a sandbox you need to pass `sandbox=false` to the exchange creation function, like `getexchange!(:okx, sandbox=false)`.

Third party apps in the `Watchers` module use the `secrets.toml` file.

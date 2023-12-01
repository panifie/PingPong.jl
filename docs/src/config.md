The bot is configured using a file named `user/pingpong.toml`, which serves as the default configuration file. This file typically contains:

- Minor exchange configurations, which are referenced using the `ExchangeID` symbol as the key for the exchange's config section.
- Strategy settings, where the strategy module's name is used as the section key. Each strategy section may include:
  - `include_file`: Specifies the path to the strategy's entry file.
  - `margin`: Defines the margin mode used when initializing the strategy.

It is generally unnecessary to populate the configuration file with numerous options, as most settings should be predefined as constants within the strategy's module. This design helps to prevent confusion that could arise from a combination of config options and strategy constants potentially conflicting with each other.

Exchange API keys are stored in dedicated files named following the pattern `\${ExchangeID}[_sandbox].json`. The `_sandbox` suffix is added for keys associated with sandbox endpoints. By default, exchanges are initiated in sandbox mode. In scenarios where an exchange does not offer a sandbox environment, the `sandbox` parameter must be explicitly set to `false` when calling the exchange creation function. Here's an example of such a call:

```julia
getexchange!(:okx, sandbox=false)
```

For third-party applications within the `Watchers` module, the configuration is managed via a separate file named `secrets.toml`.
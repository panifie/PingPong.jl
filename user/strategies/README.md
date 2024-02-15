# Symlinking strategies
If your strategy is a project, create the project folder and then symlinks the project files like this:

``` sh
mkdir user/strategies/$MY_STRATEGY
ln -sr $MY_STRATEGY_PATH/* user/strategies/$MY_STRATEGY
```

This is neccessary to ensure local projects are resolved correctly

using CSV: CSV as CSV
using DataFrames: DataFrame

const PROJECT_PATH = dirname(Base.ACTIVE_PROJECT[])
const OHLCV_FILE_PATH = joinpath(PROJECT_PATH, "test", "stubs", "ohlcv.csv")

read_ohlcv() = CSV.read(OHLCV_FILE_PATH, DataFrame)

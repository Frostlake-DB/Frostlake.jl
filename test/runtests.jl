using Test

include("testserver.jl")
include("fakeserver.jl")

@testset "Frostlake" begin
    # These need nothing installed — no engine, no JVM.
    include("json_tests.jl")
    include("sql_tests.jl")
    include("dsn_tests.jl")
    include("binding_tests.jl")
    include("values_tests.jl")
    include("result_tests.jl")

    # These boot a real engine from FROSTLAKE_CLASSPATH, and skip without one.
    include("connection_tests.jl")

    # The runner for the engine-owned JSON suites lives outside this repo, so it
    # is included only where it is present.
    suites = joinpath(@__DIR__, "suites_tests.jl")
    isfile(suites) && include(suites)
end

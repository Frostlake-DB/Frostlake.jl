using Test

include("testserver.jl")
include("fakeserver.jl")
include("scriptedserver.jl")

@testset "Frostlake" begin
    # These need nothing installed — no engine, no JVM.
    include("json_tests.jl")
    include("sql_tests.jl")
    include("dsn_tests.jl")
    include("binding_tests.jl")
    include("values_tests.jl")
    include("result_tests.jl")
    include("errors_tests.jl")

    # These boot a real engine from FROSTLAKE_CLASSPATH, and skip without one.
    include("connection_tests.jl")

    # A stand-in engine plays the session's lifetime out, and a real one
    # confirms it; the real one is skipped without FROSTLAKE_CLASSPATH.
    include("session_tests.jl")

    # The engine's testkit corpus, replayed through the driver from the testkit
    # directory FL_CORPUS names, and skipped without it.
    include("suites_tests.jl")
end

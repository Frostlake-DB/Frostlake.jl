using Test
using Frostlake: FrostlakeError, ConnectionError, QueryError, SessionLostError, UsageError

@testset "errors" begin
    @testset "every failure is a FrostlakeError" begin
        @test ConnectionError("no route") isa FrostlakeError
        @test QueryError("refused", "SELECT 1") isa FrostlakeError
        @test UsageError("bad DSN") isa FrostlakeError
        @test SessionLostError("gone", "SELECT 1") isa FrostlakeError
    end

    @testset "the printed form names the kind" begin
        @test sprint(showerror, ConnectionError("no route")) == "ConnectionError: no route"
        @test sprint(showerror, QueryError("refused", "SELECT 1")) == "QueryError: refused"
        @test sprint(showerror, UsageError("bad DSN")) == "UsageError: bad DSN"
        @test sprint(showerror, SessionLostError("gone", "SELECT 1")) == "SessionLostError: gone"
        # Any string will do for a message; it is kept as a `String`.
        @test UsageError(SubString("bad DSN", 1, 3)).message == "bad"
    end
end

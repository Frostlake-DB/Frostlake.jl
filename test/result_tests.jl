using Test
using Frostlake: Result, ColumnInfo, rows, scalar, rowcount, isupdate, columnnames,
                 columnindex

grid() = Result(
    [ColumnInfo("ID", "NUMBER", false, 38, 0), ColumnInfo("NAME", "VARCHAR", true, nothing, nothing)],
    Vector{Any}[Any[1, "Ada"], Any[2, "Grace"]],
    -1,
)

@testset "result" begin
    @testset "reading a grid" begin
        result = grid()
        @test length(result) == 2
        @test !isempty(result)
        @test columnnames(result) == ["ID", "NAME"]
        @test rowcount(result) == 2
        @test !isupdate(result)
        @test scalar(result) == 1
        @test result.values == [[1, "Ada"], [2, "Grace"]]
        @test rows(result) == [Dict("ID" => 1, "NAME" => "Ada"),
                               Dict("ID" => 2, "NAME" => "Grace")]
        # Built once and kept.
        @test rows(result) === rows(result)
    end

    @testset "indexing and iteration" begin
        result = grid()
        @test result[1] == [1, "Ada"]
        @test result[2, 2] == "Grace"
        @test result[1, "NAME"] == "Ada"
        # The engine upper-cases names; a caller need not.
        @test result[1, "name"] == "Ada"
        @test_throws KeyError result[1, "missing"]
        @test columnindex(result, "ID") == 1
        @test columnindex(result, "nope") == 0
        @test [row[1] for row in result] == [1, 2]
        @test collect(result) == [[1, "Ada"], [2, "Grace"]]
        @test result[end] == [2, "Grace"]
    end

    @testset "duplicate names keep the lossless view" begin
        # A self-join reports ID twice; a dictionary cannot hold both, which is
        # why `values` is there.
        result = Result([ColumnInfo("ID", "NUMBER", nothing, nothing, 0),
                         ColumnInfo("ID", "NUMBER", nothing, nothing, 0)],
                        Vector{Any}[Any[1, 2]], -1)
        @test result.values[1] == [1, 2]
        @test length(rows(result)[1]) == 1
        @test rows(result)[1]["ID"] == 2
    end

    @testset "a DML answer" begin
        result = Result([ColumnInfo("number of rows inserted", "NUMBER", nothing, 38, 0)],
                        Vector{Any}[Any[3]], 3, Dict("number of rows inserted" => 3))
        @test isupdate(result)
        @test rowcount(result) == 3
        @test result.updatecount == 3
        @test result.counters["number of rows inserted"] == 3
        # The grid itself is kept rather than folded away.
        @test result.values == [[3]]
    end

    @testset "an empty answer" begin
        result = Result(ColumnInfo[], Vector{Any}[], -1)
        @test isempty(result)
        @test scalar(result) === nothing
        @test rowcount(result) == 0
        @test rows(result) == Dict{String,Any}[]
        @test occursin("0 row(s)", sprint(show, result))
    end

    @testset "short rows read as NULL" begin
        result = Result([ColumnInfo("A", "VARCHAR", nothing, nothing, nothing),
                         ColumnInfo("B", "VARCHAR", nothing, nothing, nothing)],
                        Vector{Any}[Any["only"]], -1)
        @test rows(result)[1]["B"] === nothing
    end
end

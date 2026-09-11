using Test
using Dates
using Frostlake: scan_placeholders, placeholder_count, placeholder_names,
                 substitute_positional, substitute_named, format_literal,
                 encode_string_literal, split_statements, ZonedTimestamp, UsageError

@testset "binding" begin
    @testset "finding placeholders" begin
        @test placeholder_count("SELECT ?, ?") == 2
        @test placeholder_count("SELECT :a + :b") == 2
        # A name counts once however often it appears.
        @test placeholder_count("SELECT :a + :a") == 1
        @test placeholder_names("SELECT :b, :a, :b") == ["B", "A"]
        # Mixed styles are the substitution's complaint to make.
        @test placeholder_count("SELECT ?, :a") == -1

        # A marker inside a literal, identifier, comment or body is not one.
        @test placeholder_count("SELECT '?'") == 0
        @test placeholder_count("SELECT \"a?b\"") == 0
        @test placeholder_count("SELECT 1 -- ?\n") == 0
        @test placeholder_count("SELECT 1 /* ? */") == 0
        @test placeholder_count("CREATE FUNCTION f() AS \$\$ ? :x \$\$") == 0

        # `::` is a cast, `:=` an assignment, `:1` a positional reference.
        @test placeholder_count("SELECT '1'::INT") == 0
        @test placeholder_count("LET x := 1") == 0
        @test placeholder_count("SELECT :1") == 0
        # VARIANT path access reads a field; a bind marker follows a boundary.
        @test placeholder_count("SELECT v:field FROM t") == 0
        @test placeholder_count("SELECT PARSE_JSON('{}'):k") == 0
        @test placeholder_count("SELECT \"V\":k FROM t") == 0
        @test placeholder_count("SELECT OBJECT_CONSTRUCT('a',1):a") == 0
        @test placeholder_count("SELECT x[1]:k FROM t") == 0
        @test placeholder_count("SELECT (:a)") == 1
        @test placeholder_count("SELECT f(:a, :b)") == 2
    end

    @testset "positional substitution" begin
        @test substitute_positional("SELECT ?, ?", [1, "a"]) == "SELECT 1, 'a'"
        @test substitute_positional("SELECT 1", []) == "SELECT 1"
        @test substitute_positional("SELECT ?", (7,)) == "SELECT 7"
        # With no arguments at all the ? marks belong to the server too — they are
        # what a Snowflake Scripting cursor placeholder looks like, bound later by
        # `OPEN c USING (...)`. A count mismatch is still an error in both directions.
        @test substitute_positional("SELECT ?", []) == "SELECT ?"
        @test_throws UsageError substitute_positional("SELECT ?", [1, 2])
        @test_throws UsageError substitute_positional("SELECT ?, :a", [1, 2])
        @test_throws UsageError substitute_positional("SELECT :a", [1])
        # With no arguments at all the colon references belong to the server —
        # they are what Snowflake Scripting variables look like.
        @test substitute_positional("EXECUTE IMMEDIATE :v", []) == "EXECUTE IMMEDIATE :v"
        # Only the marker is replaced; the text around it survives verbatim.
        @test substitute_positional("SELECT '?', ? -- ?", [1]) == "SELECT '?', 1 -- ?"
        @test substitute_positional("SELECT ? AS \"żółw\"", ["ó"]) == "SELECT 'ó' AS \"żółw\""
    end

    @testset "named substitution" begin
        @test substitute_named("SELECT :a + :b", Dict("a" => 1, "b" => 2)) == "SELECT 1 + 2"
        # Names match case-insensitively and order does not matter.
        @test substitute_named("SELECT :A", Dict("a" => 1)) == "SELECT 1"
        @test substitute_named("SELECT :a", Dict(:a => 1)) == "SELECT 1"
        @test substitute_named("SELECT :a, :a", Dict("a" => 5)) == "SELECT 5, 5"
        @test substitute_named("SELECT 1", Dict{String,Any}()) == "SELECT 1"
        @test_throws UsageError substitute_named("SELECT :a", Dict("b" => 1))
        @test_throws UsageError substitute_named("SELECT :a", Dict("a" => 1, "z" => 2))
        @test_throws UsageError substitute_named("SELECT ?", Dict("a" => 1))
        @test_throws UsageError substitute_named("SELECT 1", Dict("a" => 1))
    end

    @testset "literals" begin
        @test format_literal(nothing) == "NULL"
        @test format_literal(missing) == "NULL"
        @test format_literal(true) == "TRUE"
        @test format_literal(false) == "FALSE"
        @test format_literal(42) == "42"
        # A negative in parentheses: bare after a minus it would open a -- comment.
        @test format_literal(Int8(-3)) == "(-3)"
        @test format_literal(-1.5) == "(-1.5)"
        @test substitute_positional("SELECT 3-?", [-5]) == "SELECT 3-(-5)"
        @test substitute_positional("SELECT 3-?", [5]) == "SELECT 3-5"
        @test format_literal(big"123456789012345678901234567890") ==
              "123456789012345678901234567890"
        @test format_literal(1.5) == "1.5"
        @test format_literal(0.1) == "0.1"
        @test format_literal(Float32(2.5)) == "2.5"
        # Julia spells these NaN, Inf and -Inf, which the parser reads as
        # identifiers.
        @test format_literal(NaN) == "'NaN'::FLOAT"
        @test format_literal(Inf) == "'Infinity'::FLOAT"
        @test format_literal(-Inf) == "'-Infinity'::FLOAT"
        # The engine's calendar stops at 9999; Dates.format would keep four digits.
        @test format_literal(Date(1, 1, 1)) == "'0001-01-01'::DATE"
        @test_throws UsageError format_literal(Date(10000, 1, 1))
        @test_throws UsageError format_literal(Date(-1, 1, 1))

        @test format_literal("plain") == "'plain'"
        @test format_literal("it's") == "'it''s'"
        @test format_literal("back\\slash") == "'back\\\\slash'"
        @test encode_string_literal("") == "''"

        # Vector{UInt8} is the deliberate marker for binary; a Vector{Int} is an
        # array of numbers.
        @test format_literal(UInt8[0xde, 0xad, 0x00]) == "X'DEAD00'"
        @test format_literal(UInt8[]) == "X''"
        @test format_literal([1, 2]) == "[1, 2]"
        @test format_literal(Any[1, "a", nothing]) == "[1, 'a', NULL]"
        @test format_literal(Dict("k" => 1, "a" => "x")) == "{'a': 'x', 'k': 1}"
        @test format_literal(Dict(:k => [1])) == "{'k': [1]}"
        @test_throws UsageError format_literal(Dict(1 => "x"))

        @test format_literal(Date(2024, 3, 4)) == "'2024-03-04'::DATE"
        @test format_literal(Time(1, 2, 3)) == "'01:02:03'::TIME"
        @test format_literal(Time(1, 2, 3, 456)) == "'01:02:03.456'::TIME"
        @test format_literal(Time(0, 0, 0, 0, 0, 7)) == "'00:00:00.000000007'::TIME"
        # A Julia DateTime is a wall clock with no zone, which is what NTZ is.
        @test format_literal(DateTime(2024, 3, 4, 1, 2, 3, 456)) ==
              "'2024-03-04 01:02:03.456'::TIMESTAMP_NTZ"
        @test format_literal(ZonedTimestamp(DateTime(2024, 1, 15, 10, 30), Second(3600))) ==
              "'2024-01-15 10:30:00.000 +01:00'::TIMESTAMP_TZ"
        @test format_literal(ZonedTimestamp(DateTime(2024, 1, 15, 10, 30), Second(-28800))) ==
              "'2024-01-15 10:30:00.000 -08:00'::TIMESTAMP_TZ"

        @test_throws UsageError format_literal(:symbol)
        @test_throws UsageError format_literal(1 + 2im)
    end

    @testset "markers next to text outside ASCII" begin
        # A marker can sit directly after a multi-byte character, whose last
        # byte is not an index `String` will slice at.
        @test substitute_positional("SELECT ż?", [1]) == "SELECT ż1"
        @test substitute_positional("SELECT 'żółw', ?", ["ó"]) == "SELECT 'żółw', 'ó'"
        @test substitute_positional("SELECT ?, 'ż'", [1]) == "SELECT 1, 'ż'"
        @test substitute_named("SELECT ż:a", Dict("a" => 1)) == "SELECT ż1"
        @test substitute_positional("SELECT '😀' || ?", ["x"]) == "SELECT '😀' || 'x'"
        @test placeholder_count("SELECT 'ż?'") == 0
    end

    @testset "injection cannot escape a literal" begin
        rendered = substitute_positional("SELECT ?", ["'; DROP TABLE t --"])
        @test rendered == "SELECT '''; DROP TABLE t --'"
        # One statement, not two: the quote was doubled rather than closed.
        @test length(split_statements(rendered)) == 1
    end
end

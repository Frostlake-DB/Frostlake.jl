using Test
using Frostlake: skip_enclosure, skip_string, skip_quoted, skip_dollar_quoted,
                 opens_dollar_quote, split_statements, changes_session_scope,
                 leading_words

@testset "sql scanner" begin
    @testset "enclosures" begin
        # `skip_enclosure` answers with the index just past the region, or 0.
        @test skip_enclosure("'abc' rest", 1) == 6
        @test skip_enclosure("x", 1) == 0
        # A doubled quote stays inside the literal, and so does a backslash
        # escape — a backslash always escapes in Frostlake's dialect.
        @test skip_enclosure("'it''s' rest", 1) == 8
        @test skip_enclosure("'a\\'b' rest", 1) == 7
        # An unterminated literal runs to the end rather than looping.
        @test skip_enclosure("'unterminated", 1) == 14

        @test skip_enclosure("\"Odd Name\" rest", 1) == 11
        @test skip_enclosure("\"a\"\"b\" rest", 1) == 7

        @test skip_enclosure("-- comment\nSELECT", 1) == 12
        @test skip_enclosure("// comment\nSELECT", 1) == 12
        @test skip_enclosure("/* c */ SELECT", 1) == 8
        @test skip_enclosure("/* unterminated", 1) == 16
        @test skip_enclosure("- x", 1) == 0
        @test skip_enclosure("/ x", 1) == 0

        @test skip_enclosure("\$\$ body \$\$ rest", 1) == 11
        # A `$` is legal inside an identifier, so `A$$B` is a name.
        @test !opens_dollar_quote("A\$\$B", 2)
        @test opens_dollar_quote(" \$\$x\$\$", 2)
        @test skip_enclosure("A\$\$B", 2) == 0
    end

    @testset "splitting statements" begin
        @test split_statements("SELECT 1") == ["SELECT 1"]
        @test split_statements("SELECT 1; SELECT 2") == ["SELECT 1", " SELECT 2"]
        # A semicolon inside a literal, an identifier, a comment or a body is
        # not a separator.
        @test length(split_statements("SELECT ';'")) == 1
        @test length(split_statements("SELECT \"a;b\"")) == 1
        @test length(split_statements("SELECT 1 -- ;\n")) == 1
        @test length(split_statements("CREATE FUNCTION f() AS \$\$ a; b \$\$")) == 1
        @test split_statements("SELECT 1;") == ["SELECT 1", ""]
    end

    @testset "session scope" begin
        for sql in ("USE DATABASE db", "use schema s", "SET x = 1", "UNSET x",
                    "ALTER SESSION SET TIMEZONE = 'UTC'",
                    "CREATE DATABASE db", "CREATE OR REPLACE DATABASE db",
                    "DROP SCHEMA IF EXISTS s", "CREATE TRANSIENT SCHEMA s",
                    "SELECT 1; USE DATABASE db")
            @test changes_session_scope(sql)
        end
        # DDL that leaves the scope exactly where it was must not mark the
        # session dirty, or every CREATE TABLE would.
        for sql in ("SELECT 1", "CREATE TABLE t (a INT)", "DROP TABLE t",
                    "ALTER TABLE t ADD COLUMN b INT", "INSERT INTO t VALUES (1)",
                    "", "-- USE DATABASE db")
            @test !changes_session_scope(sql)
        end
        # A leading comment is stepped over, a leading literal is not a keyword.
        @test changes_session_scope("/* c */ USE DATABASE db")
        @test !changes_session_scope("'USE' DATABASE db")
    end

    @testset "text outside ASCII" begin
        # The scanner walks bytes, and the byte before a delimiter can be the
        # tail of a multi-byte character — which `String` indexing refuses to
        # slice at. Every one of these used to throw a StringIndexError, and
        # `changes_session_scope` runs on every statement the driver sends.
        @test split_statements("SELECT 1 -- ż") == ["SELECT 1 -- ż"]
        @test split_statements("SELECT ż;") == ["SELECT ż", ""]
        @test split_statements("SELECT 'żółw'; SELECT 'ó'") == ["SELECT 'żółw'", " SELECT 'ó'"]
        @test split_statements("SELECT '😀'") == ["SELECT '😀'"]
        @test !changes_session_scope("SELECT 'żółw'")
        @test changes_session_scope("USE DATABASE \"żółw\"")
        @test leading_words("SELECT ż", 2) == ["SELECT"]
    end

    @testset "leading words" begin
        @test leading_words("select  Distinct * from t", 3) == ["SELECT", "DISTINCT"]
        @test leading_words("-- c\n/* c */ USE DATABASE db", 2) == ["USE", "DATABASE"]
        @test leading_words("", 3) == String[]
        @test leading_words("'literal'", 3) == String[]
        @test length(leading_words("a b c d e f g", 4)) == 4
    end

    @testset "unfinished text" begin
        # An unterminated quoted identifier runs to the end rather than looping.
        @test skip_enclosure("\"abc", 1) == 5
        # A verb whose object is never named leaves the scope alone.
        @test !changes_session_scope("DROP IF EXISTS")
        @test !changes_session_scope("CREATE OR REPLACE")
    end
end

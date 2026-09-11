# Integration tests: every statement here travels the driver's own HTTP path to a
# real engine. Nothing is mocked, and without an engine they skip rather than
# passing on a stub.

using Test
using Dates
using Sockets
using Frostlake

isdefined(@__MODULE__, :TestServer) || include("testserver.jl")
isdefined(@__MODULE__, :FakeServer) || include("fakeserver.jl")

const SKIP = TestServer.skip_reason()

if SKIP !== nothing
    @info "skipping the integration tests: $SKIP"
end

@testset "connection" begin
    if SKIP !== nothing
        @test_skip "an engine is needed"
    else
        server = TestServer.start()
        try
            @testset "connecting" begin
                conn = Connection(server.dsn)
                try
                    @test isopen(conn)
                    @test base_url(conn) == replace(server.dsn, "frostlake://" => "http://")
                    @test ping(conn) === nothing
                    # The session id appears once the session exists.
                    @test session_id(conn) === nothing
                    execute(conn, "SELECT 1")
                    @test session_id(conn) isa String
                    @test !in_transaction(conn)
                finally
                    close(conn)
                end
                @test !isopen(conn)
                # Closing twice is not an error; using a closed connection is.
                @test close(conn) === nothing
                @test_throws UsageError execute(conn, "SELECT 1")

                # The do-block form closes on the way out.
                closed_inside = Connection(server.dsn) do c
                    execute(c, "SELECT 1")
                    c
                end
                @test !isopen(closed_inside)
            end

            @testset "the DSN's scope is applied before connect returns" begin
                Connection(server.dsn) do c
                    execute(c, "CREATE OR REPLACE DATABASE scoped_db")
                    execute(c, "CREATE OR REPLACE SCHEMA scoped_db.scoped_schema")
                end
                Connection("$(server.dsn)/scoped_db?schema=scoped_schema") do c
                    @test uppercase(string(scalar(execute(c, "SELECT CURRENT_DATABASE()")))) ==
                          "SCOPED_DB"
                    @test uppercase(string(scalar(execute(c, "SELECT CURRENT_SCHEMA()")))) ==
                          "SCOPED_SCHEMA"
                end
                # A database that does not exist is reported here, rather than
                # surfacing later on whichever query happened to run first.
                @test_throws QueryError Connection("$(server.dsn)/no_such_db")
            end

            conn = Connection(server.dsn)
            execute(conn, "CREATE OR REPLACE DATABASE jl_test")
            execute(conn, "USE DATABASE jl_test")
            execute(conn, "CREATE OR REPLACE SCHEMA jl_schema")
            execute(conn, "USE SCHEMA jl_schema")

            @testset "DDL and DML" begin
                execute(conn, "CREATE OR REPLACE TABLE people (id INTEGER, name VARCHAR)")

                inserted = execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)",
                                   [1, "Ada", 2, "Grace"])
                @test isupdate(inserted)
                @test inserted.updatecount == 2
                @test inserted.counters["number of rows inserted"] == 2

                updated = execute(conn, "UPDATE people SET name = ? WHERE id = ?", ["Lovelace", 1])
                @test updated.updatecount == 1
                # "number of multi-joined rows updated" is a sub-count of rows
                # already counted, so it is kept but not summed.
                @test haskey(updated.counters, "number of multi-joined rows updated")

                deleted = execute(conn, "DELETE FROM people WHERE id = 2")
                @test deleted.updatecount == 1

                merged = execute(conn, """
                    MERGE INTO people t USING (SELECT 1 AS id) s ON t.id = s.id
                    WHEN MATCHED THEN UPDATE SET name = 'Merged'
                    WHEN NOT MATCHED THEN INSERT VALUES (s.id, 'New')""")
                # A MERGE reports an inserted and an updated count separately.
                @test merged.updatecount == 1
                @test length(merged.counters) == 2

                # DDL still answers: with no grid before engine 0.1.0, with a
                # one-row status grid from 0.1.0 on, as live does. Either way it
                # is not an update.
                ddl = execute(conn, "CREATE OR REPLACE TABLE unused (a INT)")
                @test length(ddl) <= 1
                @test ddl.updatecount == -1
            end

            @testset "reading a grid" begin
                execute(conn, "CREATE OR REPLACE TABLE grid (id INTEGER, name VARCHAR)")
                execute(conn, "INSERT INTO grid VALUES (1, 'Ada'), (2, 'Grace')")
                result = execute(conn, "SELECT id, name FROM grid ORDER BY id")
                @test columnnames(result) == ["ID", "NAME"]
                @test result.columns[1].datatype == "NUMBER"
                @test result.columns[1].scale == 0
                @test result.values == [[1, "Ada"], [2, "Grace"]]
                @test rows(result)[2]["NAME"] == "Grace"
                @test result[1, "ID"] == 1
                @test rowcount(result) == 2
                @test scalar(execute(conn, "SELECT COUNT(*) FROM grid")) == 2
            end

            @testset "types come back as themselves" begin
                result = execute(conn, """
                    SELECT 42 AS i, 3.5 AS f, 'text' AS s, TRUE AS b, NULL AS n,
                           X'DEADBEEF' AS bin,
                           12345678901234567890123456789012345678 AS big,
                           DATE '2024-01-15' AS d, TIME '10:30:45' AS t,
                           '2024-01-15 10:30:45.123'::TIMESTAMP_NTZ AS ts,
                           '2024-01-15 10:30:45.123 +01:00'::TIMESTAMP_TZ AS tz,
                           PARSE_JSON('{"a":1}') AS v""")
                row = rows(result)[1]
                @test row["I"] === 42
                @test row["F"] === 3.5
                @test row["S"] == "text"
                @test row["B"] === true
                @test row["N"] === nothing
                @test row["BIN"] == UInt8[0xde, 0xad, 0xbe, 0xef]
                @test row["BIG"] == big"12345678901234567890123456789012345678"
                @test row["D"] == Date(2024, 1, 15)
                @test row["T"] == Time(10, 30, 45)
                @test row["TS"] == DateTime(2024, 1, 15, 10, 30, 45, 123)
                @test row["TZ"] isa ZonedTimestamp
                @test row["TZ"].datetime == DateTime(2024, 1, 15, 10, 30, 45, 123)
                @test row["V"] == "{\"a\":1}"
            end

            @testset "bound values round-trip" begin
                execute(conn, """CREATE OR REPLACE TABLE bound (
                    i INTEGER, f FLOAT, s VARCHAR, b BOOLEAN, bin BINARY,
                    d DATE, ts TIMESTAMP_NTZ, n INTEGER)""")
                execute(conn, "INSERT INTO bound VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        [7, 2.5, "it's", true, UInt8[0x01, 0xff],
                         Date(2024, 3, 4), DateTime(2024, 3, 4, 5, 6, 7, 890), nothing])
                row = rows(execute(conn, "SELECT * FROM bound"))[1]
                @test row["I"] === 7
                @test row["F"] === 2.5
                @test row["S"] == "it's"
                @test row["B"] === true
                @test row["BIN"] == UInt8[0x01, 0xff]
                @test row["D"] == Date(2024, 3, 4)
                @test row["TS"] == DateTime(2024, 3, 4, 5, 6, 7, 890)
                @test row["N"] === nothing

                # Named parameters, given either way.
                @test scalar(execute(conn, "SELECT :a + :b AS total", Dict("a" => 2, "b" => 40))) == 42
                @test scalar(execute(conn, "SELECT :a + :b AS total", (a=2, b=40))) == 42
                @test scalar(execute(conn, "SELECT ? || ?", ("con", "cat"))) == "concat"
                # A big integer is bound exactly, not through a Float64.
                @test scalar(execute(conn, "SELECT ?", [big"12345678901234567890123456789"])) ==
                      big"12345678901234567890123456789"
            end

            @testset "several statements in one request" begin
                results = execute_all(conn, "SELECT 1; SELECT 2")
                @test length(results) == 2
                @test scalar(results[1]) == 1
                @test scalar(results[2]) == 2
                # `execute` hands back the first.
                @test scalar(execute(conn, "SELECT 1; SELECT 2")) == 1
            end

            @testset "session state carries across statements" begin
                execute(conn, "CREATE OR REPLACE TEMPORARY TABLE session_only (a INT)")
                execute(conn, "INSERT INTO session_only VALUES (1)")
                @test scalar(execute(conn, "SELECT COUNT(*) FROM session_only")) == 1
                @test uppercase(string(scalar(execute(conn, "SELECT CURRENT_SCHEMA()")))) ==
                      "JL_SCHEMA"
            end

            @testset "transactions" begin
                execute(conn, "CREATE OR REPLACE TABLE acc (v INTEGER)")

                transaction(conn) do c
                    execute(c, "INSERT INTO acc VALUES (1)")
                end
                @test scalar(execute(conn, "SELECT COUNT(*) FROM acc")) == 1
                @test !in_transaction(conn)

                # The body's own error is what surfaces, and the row is gone.
                @test_throws ErrorException transaction(conn) do c
                    execute(c, "INSERT INTO acc VALUES (2)")
                    error("no")
                end
                @test scalar(execute(conn, "SELECT COUNT(*) FROM acc")) == 1
                @test !in_transaction(conn)

                # Hand-rolled control.
                begin_transaction(conn)
                @test in_transaction(conn)
                execute(conn, "INSERT INTO acc VALUES (3)")
                rollback(conn)
                @test !in_transaction(conn)
                @test scalar(execute(conn, "SELECT COUNT(*) FROM acc")) == 1

                begin_transaction(conn)
                execute(conn, "INSERT INTO acc VALUES (4)")
                commit(conn)
                @test scalar(execute(conn, "SELECT COUNT(*) FROM acc")) == 2

                # A returned value comes back out of the helper.
                @test transaction(c -> scalar(execute(c, "SELECT 9")), conn) == 9
            end

            @testset "statements are serialized on one session" begin
                execute(conn, "CREATE OR REPLACE TABLE concurrent (v INTEGER)")
                tasks = [@async execute(conn, "INSERT INTO concurrent VALUES (?)", [i])
                         for i in 1:8]
                foreach(wait, tasks)
                @test scalar(execute(conn, "SELECT COUNT(*) FROM concurrent")) == 8
                # One session throughout, which is what keeps USE and an open
                # transaction carrying from one statement to the next.
                @test scalar(execute(conn, "SELECT COUNT(*) FROM concurrent")) == 8
            end

            @testset "an idle session is put back on the DSN's scope" begin
                # The engine reclaims an idle session and quietly builds a fresh
                # one for the same id, losing the scope. Nothing in the reply
                # gives it away, so past `idleLimit` the driver re-applies the
                # DSN's scope. Dropping the database in between is what makes
                # that observable: the re-applied USE is the statement that
                # fails.
                execute(conn, "CREATE OR REPLACE DATABASE idle_db")
                idle = Connection("$(server.dsn)/idle_db?idleLimit=1ms")
                try
                    @test uppercase(string(scalar(execute(idle, "SELECT CURRENT_DATABASE()")))) ==
                          "IDLE_DB"
                    execute(conn, "DROP DATABASE idle_db")
                    sleep(0.05)
                    @test_throws QueryError execute(idle, "SELECT 1")
                finally
                    close(idle)
                end

                # ... but not once the caller has selected a scope themselves:
                # putting the DSN's defaults over their choice is its own
                # surprise.
                execute(conn, "CREATE OR REPLACE DATABASE idle_db")
                touched = Connection("$(server.dsn)/idle_db?idleLimit=1ms")
                try
                    execute(touched, "USE DATABASE jl_test")
                    execute(conn, "DROP DATABASE idle_db")
                    sleep(0.05)
                    @test scalar(execute(touched, "SELECT 1")) == 1
                finally
                    close(touched)
                end

                # CREATE DATABASE moved the shared connection onto idle_db, which
                # is gone now: put it back on its own scope for the tests after.
                execute(conn, "USE DATABASE jl_test")
                execute(conn, "USE SCHEMA jl_schema")
            end

            @testset "the engine's refusals" begin
                err = try
                    execute(conn, "SELECT * FROM no_such_table")
                    nothing
                catch e
                    e
                end
                @test err isa QueryError
                @test occursin("does not exist", err.message)
                @test err.statement == "SELECT * FROM no_such_table"
                # A refusal used to arrive as HTTP 500; the engine now answers it
                # 200 with success false. Either way it is a QueryError.
                @test err.status in (200, 500)
                @test occursin("QueryError", sprint(showerror, err))
                # The rendered statement is what was sent, parameters and all.
                bound_err = try
                    execute(conn, "SELECT * FROM no_such_table WHERE a = ?", ["secret"])
                    nothing
                catch e
                    e
                end
                @test occursin("'secret'", bound_err.statement)
                # ... and never in the message a caller would log.
                @test !occursin("secret", bound_err.message)

                @test_throws QueryError execute(conn, "NOT SQL AT ALL")
                # The endpoint refuses a blank statement itself.
                @test_throws QueryError execute(conn, "")
                # A bare ? with nothing bound is the SERVER's to reject now: the driver
                # sends it verbatim and the engine answers "Positional bind placeholder
                # '?' has no value; bind it via OPEN ... USING".
                @test_throws QueryError execute(conn, "SELECT ?")
            end

            @testset "what the driver refuses to send" begin
                @test_throws UsageError execute(conn, "SELECT ?", [1, 2])
                @test_throws UsageError execute(conn, "SELECT ?", Dict("a" => 1))
                @test_throws UsageError execute(conn, "SELECT ?", [1 + 2im])
                # Not a parameter collection at all.
                @test_throws UsageError execute(conn, "SELECT ?", 1)
            end

            close(conn)
        finally
            TestServer.stop(server)
        end
    end

    @testset "transport failures" begin
        # A port with nothing behind it.
        probe = Sockets.listen(Sockets.localhost, 0)
        dead_port = Int(Sockets.getsockname(probe)[2])
        close(probe)
        @test_throws ConnectionError Connection("frostlake://127.0.0.1:$(dead_port)")

        # Something is listening, but it is not a Frostlake engine.
        FakeServer.with_server("<html>hello from a proxy</html>") do port
            err = try
                Connection("frostlake://127.0.0.1:$(port)")
                nothing
            catch e
                e
            end
            @test err isa ConnectionError
            @test occursin("not a Frostlake response", err.message)
            @test err.status == 200
        end

        # Valid JSON, but not a Frostlake health payload.
        FakeServer.with_server("{\"other\": 1}"; content_type="application/json") do port
            @test_throws ConnectionError Connection("frostlake://127.0.0.1:$(port)")
        end

        # An HTTP error from something in the way.
        FakeServer.with_server("Bad Gateway"; status="502 Bad Gateway") do port
            err = try
                Connection("frostlake://127.0.0.1:$(port)")
                nothing
            catch e
                e
            end
            @test err isa ConnectionError
            @test occursin("502", err.message)
        end

        # A server that accepts and never answers.
        FakeServer.with_server(nothing) do port
            err = try
                Connection("frostlake://127.0.0.1:$(port)?timeout=500ms")
                nothing
            catch e
                e
            end
            @test err isa ConnectionError
            @test occursin("did not answer within 500ms", err.message)
        end
    end
end

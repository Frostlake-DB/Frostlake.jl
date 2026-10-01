# How a connection keeps its idea of the engine session in step with the
# engine's: what it asks of the engine, what it does when the session is gone,
# and how it lets go of it.

using Test
using Downloads
using Frostlake
using Frostlake: touches_session, transaction_effect, json_decode, asint

isdefined(@__MODULE__, :TestServer) || include("testserver.jl")
isdefined(@__MODULE__, :ScriptedServer) || include("scriptedserver.jl")

const SS = ScriptedServer

# The message of the SessionLostError `f()` throws, or `nothing` when it throws
# nothing; any other error propagates.
function session_lost_message(f)
    try
        f()
    catch e
        e isa SessionLostError || rethrow()
        return e.message
    end
    return nothing
end

# Runs `f(server)` against a fresh stand-in, and fails on anything it did not
# script.
function scripted(f)
    SS.with_server() do server
        f(server)
        @test isempty(server.unscripted)
    end
end

@testset "session lifetime" begin
    @testset "what a statement leaves on the session" begin
        for statement in ["USE SCHEMA s", "SET v = 1", "UNSET v",
                          "ALTER SESSION SET TIMEZONE = 'UTC'", "CREATE DATABASE d",
                          "DROP SCHEMA IF EXISTS s", "CREATE TEMPORARY TABLE t (a INT)",
                          "create or replace temp stage st",
                          "CREATE LOCAL VOLATILE TABLE t (a INT)",
                          "CREATE OR REPLACE SECURE TEMPORARY VIEW v AS SELECT 1",
                          "-- note\nCREATE TEMP TABLE t (a INT)"]
            @test touches_session(statement)
        end
        for statement in ["SELECT 1", "CREATE TABLE t (a INT)",
                          "CREATE TRANSIENT TABLE t (a INT)", "CREATE TABLE temp (a INT)",
                          "DROP TABLE t", "ALTER TABLE t ADD COLUMN b INT",
                          "SELECT 'USE SCHEMA s'"]
            @test !touches_session(statement)
        end
        for statement in ["BEGIN", "begin transaction", "BEGIN WORK", "BEGIN NAME t1",
                          "START TRANSACTION"]
            @test transaction_effect(statement) === :begins
        end
        for statement in ["COMMIT", "ROLLBACK", "commit work"]
            @test transaction_effect(statement) === :ends
        end
        # BEGIN followed by a statement opens a scripting block instead.
        for statement in ["BEGIN SELECT 1", "SELECT 1", "BEGINNING", "SELECT 'BEGIN'"]
            @test transaction_effect(statement) === :none
        end
    end

    @testset "scripted" begin
        # Over a stand-in engine: every request a scenario makes is one it
        # scripted, and every one it sent is on record.
        scope = ["USE DATABASE \"APP\"", "USE SCHEMA \"PUBLIC\""]
        ok = [SS.status_set("ok")]

        # A connection opened on an engine that reports newSession.
        function opened(server; query="")
            SS.reply!(server, SS.answer("s1"; started=true, sets=ok))
            SS.reply!(server, SS.answer("s1"; sets=ok))
            return Connection(SS.dsn(server, "/APP?schema=PUBLIC$(query)"))
        end

        # The DSN's scope on a fresh session, then the statement's answer.
        function replaced(server, id, sets)
            SS.reply!(server, SS.answer(id; started=true, sets=ok))
            SS.reply!(server, SS.answer(id; sets=ok))
            SS.reply!(server, SS.answer(id; sets=sets))
        end

        @testset "an older engine is never sent requireSession, nor a DELETE" begin
            scripted() do server
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                conn = Connection(SS.dsn(server, "/APP?schema=PUBLIC"))
                SS.reply!(server, SS.legacy_answer("old1"; sets=[SS.number_set("N", 1)]))
                @test scalar(execute(conn, "SELECT 1 AS N")) == 1
                close(conn)
                @test SS.statements(server) == [scope; "SELECT 1 AS N"]
                # The session id travels once it is known, the flag never does:
                # an older engine's parser need not accept a field it does not
                # know.
                @test all(s -> SS.session_id(s) == "old1", SS.executes(server)[2:end])
                @test !any(SS.has_require_session, server.sent)
                @test !any(s -> s.method == "DELETE", server.sent)
            end
        end

        @testset "requireSession travels once the engine is known to read it" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=[SS.number_set("N", 1)]))
                execute(conn, "SELECT 1 AS N")
                sent = SS.executes(server)
                # The first request names no session, so there is nothing to
                # require yet; its answer's newSession is what says the engine
                # understands the flag.
                @test SS.session_id(sent[1]) === nothing
                @test !SS.has_require_session(sent[1])
                for request in sent[2:end]
                    @test SS.session_id(request) == "s1"
                    @test SS.require_session(request) === true
                end
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a lost session is replaced on the scope and the statement sent once more" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                replaced(server, "s2", [SS.number_set("N", 1)])
                @test scalar(execute(conn, "SELECT 1 AS N")) == 1
                @test SS.statements(server) == [scope; "SELECT 1 AS N"; scope; "SELECT 1 AS N"]
                sent = SS.executes(server)
                # The replacement starts without an id, as a first request does.
                @test SS.session_id(sent[4]) === nothing
                @test !SS.has_require_session(sent[4])
                @test SS.session_id(sent[6]) == "s2"
                @test SS.require_session(sent[6]) === true
                @test session_id(conn) == "s2"
                @test SS.pending(server) == 0
                SS.reply!(server, SS.RELEASED)
                close(conn)
                @test server.sent[end].path == "/api/sessions/s2"
            end
        end

        @testset "a second 404 is raised, and the connection starts over after it" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                SS.reply!(server, SS.answer("s2"; started=true, sets=ok))
                SS.reply!(server, SS.answer("s2"; sets=ok))
                SS.reply!(server, SS.session_gone("s2"); status=404)
                message = session_lost_message(() -> execute(conn, "SELECT 1 AS N"))
                @test message !== nothing && occursin("just started", message)
                @test SS.statements(server) == [scope; "SELECT 1 AS N"; scope; "SELECT 1 AS N"]
                # Usable still: the next statement starts a fresh session on the
                # scope.
                replaced(server, "s3", [SS.number_set("N", 2)])
                @test scalar(execute(conn, "SELECT 2 AS N")) == 2
                @test SS.session_id(SS.executes(server)[7]) === nothing
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a lost session with an open transaction is reported, not replaced" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                begin_transaction(conn)
                @test in_transaction(conn)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                message = session_lost_message(() -> execute(conn, "INSERT INTO t VALUES (1)"))
                @test message !== nothing && occursin("transaction", message)
                @test !in_transaction(conn)
                @test isopen(conn)
                @test SS.statements(server) == [scope; "BEGIN"; "INSERT INTO t VALUES (1)"]
                # The next statement starts over on the DSN's scope, in
                # autocommit.
                replaced(server, "s2", [SS.number_set("N", 1)])
                execute(conn, "SELECT 1 AS N")
                @test SS.statements(server)[5:end] == [scope; "SELECT 1 AS N"]
                @test SS.autocommit(SS.executes(server)[end]) === true
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a transaction opened by a statement is guarded the same way" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                execute(conn, "BEGIN TRANSACTION")
                SS.reply!(server, SS.session_gone("s1"); status=404)
                message = session_lost_message(() -> execute(conn, "INSERT INTO t VALUES (1)"))
                @test message !== nothing && occursin("transaction", message)
                @test SS.pending(server) == 0
                close(conn)
            end
        end

        @testset "a transaction a COMMIT ended is no reason to refuse" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                SS.reply!(server, SS.answer("s1"; sets=ok))
                execute(conn, "BEGIN")
                execute(conn, "COMMIT")
                SS.reply!(server, SS.session_gone("s1"); status=404)
                replaced(server, "s2", [SS.number_set("N", 1)])
                @test scalar(execute(conn, "SELECT 1 AS N")) == 1
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a lost session whose context moved is reported, not replaced" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                execute(conn, "USE SCHEMA OTHER")
                SS.reply!(server, SS.session_gone("s1"); status=404)
                message = session_lost_message(() -> execute(conn, "SELECT * FROM t"))
                @test message !== nothing && occursin("context", message)
                @test SS.statements(server) == [scope; "USE SCHEMA OTHER"; "SELECT * FROM t"]
                # The next statement starts over on the DSN's scope.
                replaced(server, "s2", [SS.number_set("N", 1)])
                execute(conn, "SELECT 1 AS N")
                @test SS.statements(server)[5:end] == [scope; "SELECT 1 AS N"]
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a variable, a setting or a temporary object is context too" begin
            for statement in ["SET v = 1", "ALTER SESSION SET TIMEZONE = 'UTC'",
                              "CREATE TEMPORARY TABLE scratch (a INT)",
                              "SELECT 1; USE SCHEMA OTHER"]
                scripted() do server
                    conn = opened(server)
                    SS.reply!(server, SS.answer("s1"; sets=ok))
                    execute_all(conn, statement; multi_statement_count=0)
                    SS.reply!(server, SS.session_gone("s1"); status=404)
                    message = session_lost_message(() -> execute(conn, "SELECT 2"))
                    @test message !== nothing && occursin("context", message)
                    close(conn)
                    @test SS.pending(server) == 0
                end
            end
        end

        @testset "an ordinary statement leaves nothing a replacement would miss" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                execute(conn, "CREATE TABLE t (a INT)")
                SS.reply!(server, SS.session_gone("s1"); status=404)
                replaced(server, "s2", [SS.number_set("N", 1)])
                @test scalar(execute(conn, "SELECT 1 AS N")) == 1
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "putting the DSN's scope back makes a moved session replaceable again" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                execute(conn, "USE SCHEMA OTHER")
                SS.reply!(server, SS.answer("s1"; sets=ok))
                SS.reply!(server, SS.answer("s1"; sets=ok))
                apply_dsn_scope(conn)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                replaced(server, "s2", [SS.number_set("N", 1)])
                @test scalar(execute(conn, "SELECT 1 AS N")) == 1
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "BEGIN on a lost session is re-sent on a fresh one" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                replaced(server, "s2", ok)
                begin_transaction(conn)
                @test in_transaction(conn)
                @test SS.statements(server) == [scope; "BEGIN"; scope; "BEGIN"]
                # Both went out with autocommit off, the mode the transaction
                # runs in.
                @test SS.autocommit(SS.executes(server)[3]) === false
                @test SS.autocommit(SS.executes(server)[6]) === false
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "a COMMIT whose session is gone is reported, not re-sent" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.answer("s1"; sets=ok))
                begin_transaction(conn)
                SS.reply!(server, SS.session_gone("s1"); status=404)
                message = session_lost_message(() -> commit(conn))
                @test message !== nothing && occursin("transaction", message)
                @test !in_transaction(conn)
                @test SS.statements(server) == [scope; "BEGIN"; "COMMIT"]
                close(conn)
            end
        end

        @testset "the idle re-scope is left to engines that cannot report a lost session" begin
            scripted() do server
                # An older engine gives nothing away, so an idle session is
                # assumed lost and the scope goes back on.
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                old = Connection(SS.dsn(server, "/APP?schema=PUBLIC&idleLimit=1ms"))
                sleep(0.02)
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                SS.reply!(server, SS.legacy_answer("old1"; sets=ok))
                SS.reply!(server, SS.legacy_answer("old1"; sets=[SS.number_set("N", 1)]))
                execute(old, "SELECT 1 AS N")
                @test SS.statements(server) == [scope; scope; "SELECT 1 AS N"]
                close(old)

                # One that reports newSession refuses a lost session instead, so
                # the clock is not needed.
                empty!(server.sent)
                conn = opened(server; query="&idleLimit=1ms")
                sleep(0.02)
                SS.reply!(server, SS.answer("s1"; sets=[SS.number_set("N", 1)]))
                execute(conn, "SELECT 1 AS N")
                @test SS.statements(server) == [scope; "SELECT 1 AS N"]
                SS.reply!(server, SS.RELEASED)
                close(conn)
            end
        end

        @testset "closing releases the session with one DELETE" begin
            scripted() do server
                conn = opened(server)
                SS.reply!(server, SS.RELEASED)
                close(conn)
                release = server.sent[end]
                @test release.method == "DELETE"
                @test release.path == "/api/sessions/s1"
                @test SS.pending(server) == 0
                sent_before = length(server.sent)
                close(conn)
                @test length(server.sent) == sent_before
                @test session_id(conn) === nothing
                @test_throws UsageError execute(conn, "SELECT 1")
            end
        end

        @testset "a scope the engine refuses fails the connect and releases the session" begin
            scripted() do server
                SS.reply!(server, SS.refused("s9", "Database 'APP' does not exist or not authorized."))
                SS.reply!(server, SS.RELEASED)
                @test_throws QueryError Connection(SS.dsn(server, "/APP?schema=PUBLIC"))
                @test server.sent[end].method == "DELETE"
                @test server.sent[end].path == "/api/sessions/s9"
            end
        end

        @testset "a release that fails is no failure of close" begin
            for (label, script!, query) in [
                    ("a 404", s -> SS.reply!(s, "{\"success\":false,\"sessionId\":null}"; status=404), ""),
                    ("a 405", s -> SS.reply!(s, ""; status=405), ""),
                    ("a socket closed without an answer", SS.drop!, ""),
                    # Bounded by the connection's timeout when that is the shorter.
                    ("an engine that never answers", SS.hang!, "&timeout=300ms")]
                @testset "$label" begin
                    scripted() do server
                        conn = opened(server; query=query)
                        script!(server)
                        @test close(conn) === nothing
                        @test count(s -> s.method == "DELETE", server.sent) == 1
                        @test !isopen(conn)
                    end
                end
            end
        end
    end

    @testset "against an engine" begin
        reason = TestServer.skip_reason()
        if reason !== nothing
            @test_skip "an engine is needed"
        else
            server = TestServer.start()
            try
                base = replace(server.dsn, "frostlake://" => "http://")
                # Ends a session behind the driver's back, as an idle expiry would.
                release_out_of_band(id) = Downloads.request(
                    "$(base)/api/sessions/$(id)"; method="DELETE", output=devnull, throw=false).status
                function active_sessions()
                    out = IOBuffer()
                    Downloads.request("$(base)/api/sessions"; output=out)
                    return asint(json_decode(String(take!(out)))["activeSessions"])
                end
                Connection(server.dsn) do c
                    execute(c, "CREATE OR REPLACE DATABASE sess_db")
                    execute(c, "CREATE OR REPLACE SCHEMA sess_db.sess_schema")
                end
                scoped = "$(server.dsn)/sess_db?schema=sess_schema"

                @testset "a session released out of band is replaced on the DSN's scope" begin
                    Connection(scoped) do conn
                        lost = session_id(conn)
                        @test release_out_of_band(lost) == 200
                        current = execute(conn, "SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()")
                        @test current.values == [["SESS_DB", "SESS_SCHEMA"]]
                        @test session_id(conn) != lost
                    end
                end

                @testset "a session lost with BEGIN open is reported, and nothing is re-run" begin
                    Connection(scoped) do conn
                        execute(conn, "CREATE OR REPLACE TABLE kept (id INTEGER)")
                        execute(conn, "BEGIN")
                        execute(conn, "INSERT INTO kept VALUES (1)")
                        @test release_out_of_band(session_id(conn)) == 200
                        message = session_lost_message(
                            () -> execute(conn, "INSERT INTO kept VALUES (2)"))
                        @test message !== nothing && occursin("transaction", message)
                        # A fresh session on the DSN's scope: the release rolled
                        # the first INSERT back, and the second never ran.
                        @test scalar(execute(conn, "SELECT COUNT(*) FROM kept")) == 0
                    end
                end

                @testset "a session lost after a USE is reported" begin
                    Connection(scoped) do conn
                        execute(conn, "USE SCHEMA sess_db.public")
                        @test release_out_of_band(session_id(conn)) == 200
                        @test_throws SessionLostError execute(conn, "SELECT CURRENT_SCHEMA()")
                        @test scalar(execute(conn, "SELECT CURRENT_SCHEMA()")) == "SESS_SCHEMA"
                    end
                end

                @testset "closing releases the session" begin
                    before = active_sessions()
                    conn = Connection(scoped)
                    @test active_sessions() == before + 1
                    close(conn)
                    @test active_sessions() == before
                end
            finally
                TestServer.stop(server)
            end
        end
    end
end

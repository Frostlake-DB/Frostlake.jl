# A real `DatabaseHttpServer`, booted from an engine classpath for the tests
# that need one.
#
# Nothing here is mocked: every statement the integration tests run travels the
# driver's own HTTP path to a live engine. Without `FROSTLAKE_CLASSPATH` there is
# no server, and the tests that need one skip themselves rather than passing on a
# stub — a green suite that never reached an engine would be worse than a skipped
# one.

module TestServer

using Sockets
using Downloads

"The engine classpath the tests were given, or `nothing` when they were given none."
function classpath()
    value = get(ENV, "FROSTLAKE_CLASSPATH", "")
    return isempty(value) ? nothing : value
end

"Why the integration tests cannot run, or `nothing` when they can."
skip_reason() = classpath() === nothing ?
    "FROSTLAKE_CLASSPATH is not set, so no engine can be started" : nothing

function java_command()
    home = get(ENV, "JAVA_HOME", "")
    isempty(home) && return "java"
    candidate = joinpath(home, "bin", Sys.iswindows() ? "java.exe" : "java")
    return isfile(candidate) ? candidate : "java"
end

mutable struct Server
    "A DSN pointing at this server, with no database or schema selected."
    dsn::String
    port::Int
    process::Base.Process
    logfile::String
    "The engine's private home directory for this run."
    home::String
end

"""
    start() -> Server

Boots a server on a free port and waits for it to answer.
"""
function start()
    cp = classpath()
    cp === nothing && error("FROSTLAKE_CLASSPATH is not set")

    # Bind port 0 to have the OS name a free one, then hand it straight to the
    # engine. A race is possible in principle and has never been the problem in
    # practice; picking a fixed port collides with a developer's own server.
    probe = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(probe)[2])
    close(probe)

    logfile = joinpath(tempdir(), "frostlake-julia-server-$(port).log")
    log = open(logfile, "w")
    # A default-configured engine persists outside its working directory —
    # stages under ~/.frostlake_stages, the catalog under ~/.frostlake_engine when
    # persistence is on — so consecutive runs would inherit each other's objects.
    # This run gets its own home, which also keeps db-engine.log out of the repo.
    home = mktempdir(; prefix="frostlake-julia-engine-")
    cmd = `$(java_command()) -Duser.home=$home -cp $cp dev.frostlake.http.DatabaseHttpServer $port`
    cmd = Cmd(addenv(cmd, "SQL_ENGINE_DATA_DIR" => joinpath(home, "data")); dir=home)
    # A real log file, not devnull: the log is what says why a boot failed.
    process = run(pipeline(cmd; stdout=log, stderr=log); wait=false)

    server = Server("frostlake://127.0.0.1:$(port)", port, process, logfile, home)
    if !wait_until_healthy(port)
        stop(server)
        error("the engine did not answer /api/health within 60s; see $logfile")
    end
    return server
end

function wait_until_healthy(port::Int; seconds::Int=60)
    deadline = time() + seconds
    while time() < deadline
        answer = try
            Downloads.request("http://127.0.0.1:$(port)/api/health";
                              output=devnull, throw=false, timeout=5)
        catch
            nothing
        end
        (answer !== nothing && answer isa Downloads.Response && answer.status == 200) && return true
        sleep(0.1)
    end
    return false
end

function stop(server::Server)
    try
        kill(server.process)
    catch
        # Already gone.
    end
    try
        wait(server.process)
    catch
    end
    try
        rm(server.home; recursive=true, force=true)
    catch
        # A handle still held by the dying JVM; the temp directory can wait.
    end
    return nothing
end

end # module TestServer

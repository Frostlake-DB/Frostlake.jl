# Runs the engine-owned, language-neutral JSON test suites through THIS driver.
#
# The definitions live in the frostlake repo
# (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next to
# them); every statement travels `connect` -> HTTP -> `DatabaseHttpServer`. The
# engine owns the definitions and this file is only the Julia driver's runner, so
# suites added on the engine side are picked up here with no driver change at
# all.
#
#     FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
#         JAVA_HOME=... FROSTLAKE_CLASSPATH=... julia --project -e 'using Pkg; Pkg.test()'
#
# `FL_CORPUS` names that testkit directory, and the run replays its
# `suites/*.json`. Without `FL_CORPUS` the replay is skipped, and so it is without
# `FROSTLAKE_CLASSPATH` — never falsely green; an `FL_CORPUS` holding no suites
# fails. `FROSTLAKE_TESTKIT_FILTER` narrows the run to the suites whose file name
# contains it.
#
# Semantics (mirrors SCHEMA.md and the Go, Ruby, dotnet and Dart runners):
#  * backend name for a suite's skip clause: `julia`; `http` entries are honoured
#    too, because this driver rides the HTTP transport and the same engine.
#  * per-test isolation: `CREATE OR REPLACE DATABASE test_db` -> `USE` ->
#    `CREATE OR REPLACE SCHEMA test_schema` -> `USE`, then the steps on ONE
#    connection, which is what keeps USE, variables and transactions on a single
#    session.
#  * capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE — the HTTP
#    protocol carries a message only, so expected-error code/sqlState checks are
#    recorded as missing-API notes instead of failing.

using Test
using Dates
using Printf
using Frostlake
using Frostlake: json_decode, JSONNumber, JSONParseError, base_type_name,
                 format_time, format_naive, ZonedTimestamp

isdefined(@__MODULE__, :TestServer) || include("testserver.jl")

const BACKEND = "julia"

# Capabilities this transport cannot express, and the driver limits a case ran
# into. Written out next to the results rather than failed on.
const NOTES = Set{String}()

"What one step produced: a grid, an update count, or a failure."
struct Outcome
    columns::Vector{String}
    rows::Vector{Vector{Union{String,Nothing}}}
    updatecount::Int
    error::Union{String,Nothing}
end

Outcome(; columns=String[], rows=Vector{Union{String,Nothing}}[], updatecount=-1,
        error=nothing) = Outcome(columns, rows, updatecount, error)

"""
The canonical suites: `suites/` in the testkit directory `FL_CORPUS` names, or
`nothing` when it names none.
"""
function suites_directory()
    corpus = get(ENV, "FL_CORPUS", "")
    return isempty(corpus) ? nothing : joinpath(corpus, "suites")
end

has_suites(directory) = isdir(directory) && any(f -> endswith(f, ".json"), readdir(directory))

function suite_files(directory)
    directory === nothing && return String[]
    filter_text = get(ENV, "FROSTLAKE_TESTKIT_FILTER", "")
    files = sort!([joinpath(directory, f) for f in readdir(directory)
                   if endswith(f, ".json")])
    isempty(filter_text) && return files
    return [f for f in files if occursin(filter_text, basename(f))]
end

"A suite may declare that a backend cannot run a case."
function skip_reason_for(entry)
    skip = get(entry, "skip", nothing)
    skip isa AbstractDict || return nothing
    backends = get(skip, "backends", nothing)
    backends isa AbstractVector || return nothing
    named = Set(lowercase(string(b)) for b in backends)
    (BACKEND in named || "http" in named) || return nothing
    return string("declared in the suite: ", get(skip, "reason", "no reason given"))
end

# Set once the engine stopped answering, with the failure that showed it. One dead
# engine used to fail every remaining case on "cannot reach", thousands of times
# over; now the run stops with the reason.
const ENGINE_LOST = Ref{Union{Nothing,String}}(nothing)
const SERVER_PORT = Ref(0)

engine_answers() = SERVER_PORT[] != 0 && TestServer.wait_until_healthy(SERVER_PORT[]; seconds=5)

function run_step(conn, sql::String)
    try
        result = execute(conn, sql)
        return Outcome(
            columns=columnnames(result),
            rows=[Union{String,Nothing}[cell_text(result.values[i][j], result.columns[j])
                                        for j in eachindex(result.columns)]
                  for i in eachindex(result.values)],
            updatecount=result.updatecount,
        )
    catch e
        e isa QueryError || rethrow()
        # Only the engine's own refusal is a statement failure. A ConnectionError
        # (the transport) or a UsageError (the driver refusing to send) satisfies
        # no expectation — a dead engine must not pass an `error` step — so they
        # propagate and the case is recorded as ERROR.
        return Outcome(error=e.message)
    end
end

"""
Lets this session run a request that carries several statements.

A session runs one statement per request until it asks for more, so a case whose step sends
several would be refused on the count rather than answered; `0` means any number of them.
"""
function allow_statement_packs(conn)
    outcome = run_step(conn, "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
    outcome.error === nothing ||
        return string("could not allow statement packs: ", outcome.error)
    return nothing
end

"The reset sequence SCHEMA.md prescribes: every case starts in an empty `test_db.test_schema`."
function reset_context(conn)
    for sql in ("CREATE OR REPLACE DATABASE test_db", "USE DATABASE test_db",
                "CREATE OR REPLACE SCHEMA test_schema", "USE SCHEMA test_schema")
        outcome = run_step(conn, sql)
        outcome.error === nothing ||
            return string("resetContext failed on \"", sql, "\": ", outcome.error)
    end
    return nothing
end

"Runs one case; returns `nothing` when it passed, or the problem's description."
function run_case(dsn::String, entry)
    conn = Connection(dsn)
    try
        problem = allow_statement_packs(conn)
        problem === nothing || return problem
        problem = reset_context(conn)
        problem === nothing || return problem
        steps = get(entry, "steps", nothing)
        steps isa AbstractVector || return nothing
        for (i, step) in enumerate(steps)
            step isa AbstractDict || continue
            sql = string(get(step, "sql", ""))
            outcome = run_step(conn, sql)
            problem = check(get(step, "expect", nothing), outcome, sql)
            problem === nothing && continue
            return string("step ", i, ": ", problem, "\n  [sql: ", sql, "]")
        end
        return nothing
    finally
        close(conn)
    end
end

function check(expectation, outcome::Outcome, sql::String)
    if !(expectation isa AbstractDict)
        return outcome.error === nothing ? nothing :
               string("unexpected error: ", outcome.error)
    end

    if haskey(expectation, "error")
        outcome.error === nothing && return "expected an error, the statement succeeded"
        expected = expectation["error"]
        if expected isa AbstractDict
            contains = get(expected, "messageContains", nothing)
            if contains !== nothing &&
               !occursin(lowercase(string(contains)), lowercase(outcome.error))
                # Engines before 0.1.0 refuse a blank statement at the HTTP
                # endpoint itself — 400, "SQL is required" — so the engine never
                # runs it and never produces its own wording. Newer ones answer
                # with it and the check above passes; against an older one it is
                # a capability gap rather than a mismatch. It did still fail.
                if isempty(strip(sql))
                    push!(NOTES, "missing-API [$BACKEND] EMPTY_STATEMENT: this engine's HTTP " *
                                 "API refuses a blank statement itself (HTTP 400 \"SQL is " *
                                 "required\"), so its own \"Empty SQL statement.\" " *
                                 "error cannot be observed over this transport")
                    return nothing
                end
                return string("the error [", outcome.error, "] does not contain [", contains, "]")
            end
            if haskey(expected, "code") || haskey(expected, "sqlState")
                push!(NOTES, "missing-API [$BACKEND] ERROR_CODE: failures carry a message " *
                             "only, so an error code or SQLSTATE cannot be checked")
            end
        end
        return nothing
    end

    outcome.error === nothing || return string("unexpected error: ", outcome.error)

    if haskey(expectation, "value")
        actual = (isempty(outcome.rows) || isempty(outcome.rows[1])) ? nothing : outcome.rows[1][1]
        want = normalize(scalar_text(expectation["value"]))
        if want != normalize(actual)
            return string("value [", actual === nothing ? "NULL" : actual,
                          "] != expected [", scalar_text(expectation["value"]), "]")
        end
    end

    wanted_rows = get(expectation, "rows", nothing)
    if wanted_rows isa AbstractVector
        want = [join([normalize(scalar_text(cell)) for cell in row], " | ")
                for row in wanted_rows if row isa AbstractVector]
        got = [join([normalize(cell) for cell in row], " | ") for row in outcome.rows]
        if get(expectation, "ordered", nothing) !== true
            sort!(want)
            sort!(got)
        end
        want == got || return string("rows differ:\n    expected ", want, "\n    got      ", got)
    end

    wanted_count = get(expectation, "rowCount", nothing)
    if wanted_count !== nothing
        want = as_int(wanted_count)
        (want === nothing || length(outcome.rows) == want) ||
            return string("rowCount ", length(outcome.rows), " != expected ", want)
    end

    wanted_columns = get(expectation, "columns", nothing)
    if wanted_columns isa AbstractVector
        want = [uppercase(string(c)) for c in wanted_columns]
        got = [uppercase(c) for c in outcome.columns]
        want == got || return string("columns ", got, " != expected ", want)
    end

    wanted_update = get(expectation, "updateCount", nothing)
    if wanted_update !== nothing
        want = as_int(wanted_update)
        (want === nothing || outcome.updatecount == want) ||
            return string("updateCount ", outcome.updatecount, " != expected ", want)
    end

    return nothing
end

"""
Renders a converted cell the way the other runners' transports render theirs,
and reads a semi-structured one as the value the suites record.
"""
function cell_text(value, column::ColumnInfo)
    text = rendered_text(value)
    (text === nothing || !is_semi_structured(column.datatype)) && return text
    return semi_structured_value(text)
end

"The cell as this transport renders it, before any column-driven reading."
function rendered_text(value)
    value === nothing && return nothing
    value isa Bool && return value ? "true" : "false"
    value isa Vector{UInt8} && return uppercase(join(string(b; base=16, pad=2) for b in value))
    value isa Dates.Time && return format_time(value)
    value isa Dates.Date && return Dates.format(value, "yyyy-mm-dd")
    value isa Dates.DateTime && return format_naive(value)
    # The engine prints an offset without its colon; matching that keeps the
    # exact-string comparison honest rather than turning every zoned timestamp
    # into a formatting difference.
    if value isa ZonedTimestamp
        total = Dates.value(value.offset)
        sign = total < 0 ? "-" : "+"
        total = abs(total)
        return string(format_naive(value.datetime), " ", sign,
                      lpad(total ÷ 3600, 2, '0'), lpad((total % 3600) ÷ 60, 2, '0'))
    end
    return string(value)
end

"""
Whether a column carries semi-structured values, read from the type the engine
reported. The gate is the column's type and never the cell's shape: a VARCHAR
whose content happens to look like `"quoted"` is that text, and stays it.
"""
is_semi_structured(datatype) = base_type_name(datatype) in ("VARIANT", "OBJECT", "ARRAY")

"""
The value a semi-structured cell carries, as the suites record it.

A client is handed a VARIANT, OBJECT or ARRAY cell as its JSON *text* — a
string's own quotes included — which is what the account's own drivers do. The
suites record the value instead: `a` rather than `"a"`, and an object as its own
text rather than as a string holding that text. One level of decoding covers
both: a cell that is a JSON string becomes that string's contents, and anything
else — a number, a boolean, text that is not JSON at all — is left exactly as it
came.
"""
function semi_structured_value(text::AbstractString)
    decoded = try
        json_decode(text)
    catch e
        e isa JSONParseError || rethrow()
        # Text that is not JSON at all is a value in its own right.
        return String(text)
    end
    return decoded isa AbstractString ? String(decoded) : String(text)
end

"The scalar an expectation names, as text."
function scalar_text(value)
    value === nothing && return nothing
    value isa Bool && return value ? "true" : "false"
    value isa JSONNumber && return value.text
    return string(value)
end

function as_int(value)
    value isa JSONNumber && return tryparse(Int, value.text)
    value isa Integer && return Int(value)
    value isa AbstractString && return tryparse(Int, value)
    return nothing
end

"""
SCHEMA.md value normalization, applied to both sides before comparing:
`null`/empty becomes NULL, booleans compare case-insensitively, anything numeric
compares as a number rounded to 10 significant digits, and everything else is an
exact trimmed string.
"""
function normalize(value)
    value === nothing && return "NULL"
    text = strip(String(value))
    isempty(text) && return "NULL"
    folded = lowercase(text)
    folded == "null" && return "NULL"
    folded == "true" && return "TRUE"
    folded == "false" && return "FALSE"
    number = tryparse(Float64, text)
    if number !== nothing && isfinite(number)
        return number == 0 ? "0" : significant10(number)
    end
    return String(text)
end

"""
Ten significant digits with trailing zeros dropped, so `2` and `2.000000`
compare equal and so do `3.5` and `3.500000` — which is exactly what `%g` does.
"""
significant10(value::Float64) = @sprintf("%.10g", value)

# ------------------------------------------------------------------ the run

@testset "testkit" begin
    # FL_CORPUS is read before anything else: without it no engine is looked for,
    # and one that names no suites was pointed at the wrong place.
    directory = suites_directory()
    if directory === nothing
        skip = "set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus"
    elseif !has_suites(directory)
        error("FL_CORPUS=", ENV["FL_CORPUS"], " holds no suites/*.json; set it to frostlake's ",
              "engine/src/test/resources/testkit")
    else
        skip = TestServer.skip_reason()
    end

    if skip !== nothing
        @info "skipping the testkit suites: $skip"
        @test_skip "FL_CORPUS and an engine are needed"
    else
        files = suite_files(directory)
        @info "running $(length(files)) testkit suite file(s) from $directory"
        server = TestServer.start()
        SERVER_PORT[] = server.port
        passed = 0
        skipped = 0
        failures = Tuple{String,String,String}[]
        records = String[]
        try
            for file in files
                suite = json_decode(read(file, String))
                suite isa AbstractDict || continue
                name = replace(basename(file), ".json" => "")
                cases = get(suite, "tests", nothing)
                cases isa AbstractVector || continue
                for entry in cases
                    entry isa AbstractDict || continue
                    case_name = string(get(entry, "name", "(unnamed)"))
                    reason = skip_reason_for(entry)
                    if reason !== nothing
                        skipped += 1
                        push!(records, join([name, case_name, "SKIP", "", reason, "0"], "\t"))
                        continue
                    end
                    started = time()
                    problem = try
                        run_case(server.dsn, entry)
                    catch e
                        if e isa ConnectionError && !engine_answers()
                            ENGINE_LOST[] = e.message
                        end
                        string("ERROR: ", sprint(showerror, e))
                    end
                    elapsed = round(Int, (time() - started) * 1000)
                    if problem === nothing
                        passed += 1
                        push!(records, join([name, case_name, "PASS", "", "", string(elapsed)], "\t"))
                    else
                        status = startswith(problem, "ERROR: ") ? "ERROR" : "FAIL"
                        push!(failures, (name, case_name, problem))
                        push!(records, join([name, case_name, status, "",
                                             replace(problem, "\n" => " ", "\r" => " ", "\t" => " "),
                                             string(elapsed)], "\t"))
                    end
                    ENGINE_LOST[] === nothing || break
                end
                if ENGINE_LOST[] !== nothing
                    @error "the engine stopped answering; the remaining suites were not run" reason = ENGINE_LOST[] suite = name
                    push!(failures, (name, "(remaining suites)", string("ABORTED: ", ENGINE_LOST[])))
                    break
                end
            end
        finally
            TestServer.stop(server)
        end

        results = joinpath(dirname(@__DIR__), "results")
        mkpath(results)
        open(joinpath(results, "testkit-$(BACKEND).tsv"), "w") do io
            println(io, join(["suite", "test", "status", "failedStep", "detail", "ms"], "\t"))
            foreach(record -> println(io, record), records)
        end
        if !isempty(NOTES)
            open(joinpath(results, "missing-apis-$(BACKEND).md"), "w") do io
                println(io, "# Missing APIs — $(BACKEND) backend\n")
                foreach(note -> println(io, "- ", note), sort!(collect(NOTES)))
            end
        end

        for (suite, case, problem) in failures
            @warn "testkit FAIL" suite case problem
        end
        @info "testkit: $passed passed, $(length(failures)) failed, $skipped skipped"
        @test isempty(failures)
    end
end

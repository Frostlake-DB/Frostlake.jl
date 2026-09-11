# A tour of the driver against a running DatabaseHttpServer.
#
#     julia --project=. examples/basic.jl [dsn]
#
# Start an engine first, e.g.
#
#     java -cp "<engine classpath>" dev.frostlake.http.DatabaseHttpServer 18082

using Dates
using Frostlake

dsn = isempty(ARGS) ? "frostlake://localhost:18082" : ARGS[1]

Connection(dsn) do conn
    println("connected to ", base_url(conn), " — engine ",
            scalar(execute(conn, "SELECT CURRENT_VERSION()")))

    execute(conn, "CREATE OR REPLACE DATABASE example_db")
    execute(conn, "USE DATABASE example_db")
    execute(conn, "CREATE OR REPLACE SCHEMA example_schema")
    execute(conn, "USE SCHEMA example_schema")

    execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR, joined DATE)")

    # Positional parameters are inlined client-side, safely quoted.
    inserted = execute(conn, "INSERT INTO people VALUES (?, ?, ?), (?, ?, ?)",
                       [1, "Ada", Date(2024, 1, 15),
                        2, "Grace", Date(2024, 3, 4)])
    println("inserted ", inserted.updatecount, " row(s)")

    # ... or named ones, as a dictionary or a named tuple.
    execute(conn, "INSERT INTO people VALUES (:id, :name, :joined)",
            (id=3, name="it's a quote", joined=Date(2024, 6, 30)))

    result = execute(conn, "SELECT id, name, joined FROM people ORDER BY id")
    println("\ncolumns: ", join(("$(c.name)::$(c.datatype)" for c in result.columns), ", "))
    for row in result                      # positional, the lossless view
        println("  ", row)
    end
    for row in rows(result)                # ... or keyed by column name
        println("  ", row["ID"], " ", row["NAME"], " joined ", row["JOINED"])
    end

    println("\ncount: ", scalar(execute(conn, "SELECT COUNT(*) FROM people")))

    # A transaction commits when the body returns and rolls back when it throws.
    transaction(conn) do c
        execute(c, "DELETE FROM people WHERE id = ?", [3])
    end
    println("after commit: ", scalar(execute(conn, "SELECT COUNT(*) FROM people")))

    try
        transaction(conn) do c
            execute(c, "DELETE FROM people")
            error("changed my mind")
        end
    catch e
        println("rolled back: ", e)
    end
    println("after rollback: ", scalar(execute(conn, "SELECT COUNT(*) FROM people")))

    # Every failure is a FrostlakeError; the subtype says which kind it was.
    try
        execute(conn, "SELECT * FROM no_such_table")
    catch e
        e isa QueryError || rethrow()
        println("\nthe engine said: ", e.message)
    end

    execute(conn, "DROP DATABASE example_db")
end

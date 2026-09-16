using Documenter
using Frostlake

makedocs(;
    modules = [Frostlake],
    sitename = "Frostlake.jl",
    format = Documenter.HTML(;
        canonical = "https://Frostlake-DB.github.io/Frostlake.jl",
        edit_link = "master",
    ),
    pages = [
        "Home" => "index.md",
        "Connecting" => "connecting.md",
        "Statements and parameters" => "statements.md",
        "Results and types" => "results.md",
        "Transactions and sessions" => "transactions.md",
        "Errors" => "errors.md",
        "Known limitations" => "limitations.md",
        "Development" => "development.md",
        "API reference" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(;
    repo = "github.com/Frostlake-DB/Frostlake.jl",
    devbranch = "master",
)

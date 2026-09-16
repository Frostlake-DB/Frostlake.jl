# API reference

```@docs
Frostlake
```

## Connecting

```@docs
Connection
Frostlake.connect
ping
apply_dsn_scope
session_id
in_transaction
base_url
```

## Statements

```@docs
execute
execute_all
```

## Transactions

```@docs
transaction
begin_transaction
commit
rollback
```

## Results

```@docs
Result
ColumnInfo
rows
scalar
rowcount
isupdate
columnnames
columnindex
```

## Values

```@docs
ZonedTimestamp
utc
```

## Errors

```@docs
FrostlakeError
QueryError
ConnectionError
UsageError
```

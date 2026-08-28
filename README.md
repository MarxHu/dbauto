# dbauto

`dbauto` is a lightweight database migration and automation CLI. It applies
plain-SQL migrations to a SQLite database, tracks what has been applied, detects
when an already-applied migration file has been edited (drift), seeds
development data, and runs ad-hoc queries — all with the Python standard
library's `sqlite3` driver, so it needs no external database server.

## Features

- Plain `.sql` migrations named `<version>_<name>.sql`, applied in order.
- An applied-migrations tracking table with per-file checksums for drift detection.
- `status`, `migrate` (with `--dry-run`), `seed`, and `query` commands.
- Rich, colorized terminal output.
- Zero external services — everything runs against a local SQLite file.

## Requirements

- Python 3.10+

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
```

> In Cloud Agents this is handled automatically by `.cursor/environment.json`,
> which creates `.venv` and installs the project. Run the CLI with
> `.venv/bin/dbauto ...` (or activate the venv first).

## Usage

```bash
# Show migration status
dbauto status

# Apply all pending migrations (see them first with --dry-run)
dbauto migrate --dry-run
dbauto migrate

# Load development seed data
dbauto seed

# Inspect the database
dbauto query "SELECT id, email, full_name FROM users"
```

### Configuration

Settings resolve from CLI options, then environment variables, then defaults:

| Setting        | CLI option          | Env var                  | Default              |
| -------------- | ------------------- | ------------------------ | -------------------- |
| Database URL   | `--database-url`    | `DBAUTO_DATABASE_URL`    | `sqlite:///dbauto.db`|
| Migrations dir | `--migrations-dir`  | `DBAUTO_MIGRATIONS_DIR`  | `migrations`         |
| Seeds dir      | `--seeds-dir`       | `DBAUTO_SEEDS_DIR`       | `seeds`              |

Database URLs may be `sqlite:///relative.db`, `sqlite:////abs/path.db`, or a bare
filesystem path.

## Project layout

```
migrations/   # versioned schema migrations (*.sql)
seeds/        # development seed data (*.sql)
src/dbauto/   # the CLI and migration engine
tests/        # pytest unit tests
```

## Development

```bash
pytest        # run the test suite
```

## License

MIT

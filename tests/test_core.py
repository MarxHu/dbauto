"""Unit tests for the dbauto migration engine."""

from __future__ import annotations

from pathlib import Path

import pytest

from dbauto.core import MigrationError, MigrationRunner, parse_sqlite_path


def _write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


@pytest.fixture()
def project(tmp_path: Path):
    migrations = tmp_path / "migrations"
    migrations.mkdir()
    _write(
        migrations / "0001_create_widgets.sql",
        "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
    )
    _write(
        migrations / "0002_add_color.sql",
        "ALTER TABLE widgets ADD COLUMN color TEXT;",
    )
    db_url = f"sqlite:///{tmp_path / 'app.db'}"
    return MigrationRunner(db_url, migrations), tmp_path


def test_parse_sqlite_path_variants():
    assert parse_sqlite_path("sqlite:///rel.db") == Path("rel.db")
    assert parse_sqlite_path("sqlite:////abs.db") == Path("/abs.db")
    assert parse_sqlite_path("/tmp/app.db") == Path("/tmp/app.db")


def test_discover_orders_and_parses(project):
    runner, _ = project
    migrations = runner.discover()
    assert [m.version for m in migrations] == ["0001", "0002"]
    assert migrations[0].name == "create_widgets"


def test_migrate_applies_all_and_is_idempotent(project):
    runner, _ = project
    with runner.connect() as conn:
        applied = runner.migrate(conn)
        assert [m.version for m in applied] == ["0001", "0002"]

        # Second run applies nothing.
        assert runner.migrate(conn) == []

        # The schema is actually there.
        cols = [r[1] for r in conn.execute("PRAGMA table_info(widgets)").fetchall()]
        assert {"id", "name", "color"} <= set(cols)


def test_status_reports_pending_and_applied(project):
    runner, _ = project
    with runner.connect() as conn:
        before = runner.status(conn)
        assert all(not s.applied for s in before)

        runner.migrate(conn)
        after = runner.status(conn)
        assert all(s.applied for s in after)
        assert all(not s.drifted for s in after)


def test_status_detects_drift(project):
    runner, tmp_path = project
    with runner.connect() as conn:
        runner.migrate(conn)

    # Edit an already-applied migration file.
    (tmp_path / "migrations" / "0001_create_widgets.sql").write_text(
        "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL, extra TEXT);",
        encoding="utf-8",
    )
    with runner.connect() as conn:
        statuses = {s.migration.version: s for s in runner.status(conn)}
    assert statuses["0001"].drifted is True
    assert statuses["0002"].drifted is False


def test_missing_migrations_dir_raises(tmp_path: Path):
    runner = MigrationRunner(f"sqlite:///{tmp_path/'x.db'}", tmp_path / "missing")
    with runner.connect() as conn:
        with pytest.raises(MigrationError):
            runner.migrate(conn)


def test_seed_executes_files(project):
    runner, tmp_path = project
    seeds = tmp_path / "seeds"
    seeds.mkdir()
    _write(seeds / "0001_data.sql", "INSERT INTO widgets (name) VALUES ('bolt');")
    with runner.connect() as conn:
        runner.migrate(conn)
        executed = runner.seed(conn, seeds)
        assert len(executed) == 1
        count = conn.execute("SELECT COUNT(*) FROM widgets").fetchone()[0]
        assert count == 1

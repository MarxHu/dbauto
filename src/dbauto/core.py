"""Core migration engine for dbauto.

The engine is intentionally small and backed by the Python standard library's
``sqlite3`` module so it runs anywhere with zero external services. Migrations
are plain ``.sql`` files named ``<version>_<name>.sql`` (for example
``0001_create_users.sql``) and are applied in lexical order. Applied migrations
are tracked in a ``dbauto_migrations`` table, and a checksum is stored so the
engine can warn when a previously applied migration file has been edited.
"""

from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

TRACKING_TABLE = "dbauto_migrations"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def parse_sqlite_path(database_url: str) -> Path:
    """Return the on-disk path for a sqlite URL or a bare filesystem path.

    Supported forms:

    * ``sqlite:///relative/path.db``
    * ``sqlite:////absolute/path.db``
    * ``/absolute/path.db`` or ``relative/path.db``
    """

    prefix = "sqlite:///"
    if database_url.startswith(prefix):
        return Path(database_url[len(prefix) :])
    if database_url.startswith("sqlite://"):
        return Path(database_url[len("sqlite://") :])
    return Path(database_url)


@dataclass(frozen=True)
class Migration:
    """A single migration file on disk."""

    version: str
    name: str
    path: Path

    @property
    def sql(self) -> str:
        return self.path.read_text(encoding="utf-8")

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.sql.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class MigrationStatus:
    """The state of a migration relative to the database."""

    migration: Migration
    applied: bool
    applied_at: str | None
    drifted: bool


class MigrationError(RuntimeError):
    """Raised when a migration cannot be discovered or applied cleanly."""


class MigrationRunner:
    """Discovers, applies, and reports on SQL migrations."""

    def __init__(self, database_url: str, migrations_dir: str | Path) -> None:
        self.database_url = database_url
        self.db_path = parse_sqlite_path(database_url)
        self.migrations_dir = Path(migrations_dir)

    def connect(self) -> sqlite3.Connection:
        if self.db_path.parent and str(self.db_path.parent) not in ("", "."):
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def ensure_tracking_table(self, conn: sqlite3.Connection) -> None:
        conn.execute(
            f"""
            CREATE TABLE IF NOT EXISTS {TRACKING_TABLE} (
                version    TEXT PRIMARY KEY,
                name       TEXT NOT NULL,
                checksum   TEXT NOT NULL,
                applied_at TEXT NOT NULL
            )
            """
        )
        conn.commit()

    def discover(self) -> list[Migration]:
        if not self.migrations_dir.exists():
            raise MigrationError(
                f"Migrations directory not found: {self.migrations_dir}"
            )
        migrations: list[Migration] = []
        seen: set[str] = set()
        for path in sorted(self.migrations_dir.glob("*.sql")):
            stem = path.stem
            version, _, name = stem.partition("_")
            if not version:
                raise MigrationError(f"Migration has no version prefix: {path.name}")
            if version in seen:
                raise MigrationError(f"Duplicate migration version: {version}")
            seen.add(version)
            migrations.append(
                Migration(version=version, name=name or stem, path=path)
            )
        return migrations

    def _applied_rows(self, conn: sqlite3.Connection) -> dict[str, sqlite3.Row]:
        self.ensure_tracking_table(conn)
        rows = conn.execute(
            f"SELECT version, name, checksum, applied_at FROM {TRACKING_TABLE}"
        ).fetchall()
        return {row["version"]: row for row in rows}

    def status(self, conn: sqlite3.Connection) -> list[MigrationStatus]:
        applied = self._applied_rows(conn)
        statuses: list[MigrationStatus] = []
        for migration in self.discover():
            row = applied.get(migration.version)
            statuses.append(
                MigrationStatus(
                    migration=migration,
                    applied=row is not None,
                    applied_at=row["applied_at"] if row else None,
                    drifted=bool(row) and row["checksum"] != migration.checksum,
                )
            )
        return statuses

    def pending(self, conn: sqlite3.Connection) -> list[Migration]:
        applied = self._applied_rows(conn)
        return [m for m in self.discover() if m.version not in applied]

    def migrate(self, conn: sqlite3.Connection) -> list[Migration]:
        """Apply all pending migrations and return the ones that were applied."""

        applied_now: list[Migration] = []
        for migration in self.pending(conn):
            try:
                conn.executescript(migration.sql)
            except sqlite3.Error as exc:  # pragma: no cover - defensive
                conn.rollback()
                raise MigrationError(
                    f"Failed to apply {migration.path.name}: {exc}"
                ) from exc
            conn.execute(
                f"INSERT INTO {TRACKING_TABLE} (version, name, checksum, applied_at) "
                "VALUES (?, ?, ?, ?)",
                (migration.version, migration.name, migration.checksum, _utc_now_iso()),
            )
            conn.commit()
            applied_now.append(migration)
        return applied_now

    def seed(self, conn: sqlite3.Connection, seeds_dir: str | Path) -> list[Path]:
        """Execute every ``.sql`` file in ``seeds_dir`` in lexical order."""

        seeds_path = Path(seeds_dir)
        if not seeds_path.exists():
            raise MigrationError(f"Seeds directory not found: {seeds_path}")
        executed: list[Path] = []
        for path in sorted(seeds_path.glob("*.sql")):
            try:
                conn.executescript(path.read_text(encoding="utf-8"))
            except sqlite3.Error as exc:
                conn.rollback()
                raise MigrationError(f"Failed to seed {path.name}: {exc}") from exc
            conn.commit()
            executed.append(path)
        return executed

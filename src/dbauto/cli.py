"""Command line interface for dbauto."""

from __future__ import annotations

import sqlite3
import sys

import click
from rich.console import Console
from rich.table import Table

from . import __version__
from .config import resolve_settings
from .core import MigrationError, MigrationRunner

console = Console()
err_console = Console(stderr=True)


def _runner(ctx: click.Context) -> MigrationRunner:
    settings = ctx.obj["settings"]
    return MigrationRunner(settings.database_url, settings.migrations_dir)


@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(__version__, prog_name="dbauto")
@click.option(
    "--database-url",
    envvar="DBAUTO_DATABASE_URL",
    default=None,
    help="SQLite database URL or path (default: sqlite:///dbauto.db).",
)
@click.option(
    "--migrations-dir",
    envvar="DBAUTO_MIGRATIONS_DIR",
    default=None,
    help="Directory containing migration .sql files (default: migrations).",
)
@click.option(
    "--seeds-dir",
    envvar="DBAUTO_SEEDS_DIR",
    default=None,
    help="Directory containing seed .sql files (default: seeds).",
)
@click.pass_context
def cli(
    ctx: click.Context,
    database_url: str | None,
    migrations_dir: str | None,
    seeds_dir: str | None,
) -> None:
    """dbauto — automate SQL migrations and seeding for SQLite databases."""

    ctx.ensure_object(dict)
    ctx.obj["settings"] = resolve_settings(
        database_url=database_url,
        migrations_dir=migrations_dir,
        seeds_dir=seeds_dir,
    )


@cli.command()
@click.pass_context
def status(ctx: click.Context) -> None:
    """Show applied and pending migrations."""

    runner = _runner(ctx)
    try:
        with runner.connect() as conn:
            statuses = runner.status(conn)
    except MigrationError as exc:
        err_console.print(f"[bold red]Error:[/] {exc}")
        raise SystemExit(1)

    table = Table(title="dbauto migrations", show_lines=False)
    table.add_column("Version", style="cyan", no_wrap=True)
    table.add_column("Name", style="white")
    table.add_column("Status")
    table.add_column("Applied at", style="dim")

    pending = 0
    for item in statuses:
        if item.applied and item.drifted:
            state = "[yellow]drifted[/]"
        elif item.applied:
            state = "[green]applied[/]"
        else:
            state = "[magenta]pending[/]"
            pending += 1
        table.add_row(
            item.migration.version,
            item.migration.name,
            state,
            item.applied_at or "—",
        )

    console.print(table)
    console.print(
        f"[bold]{len(statuses)}[/] migration(s), [magenta]{pending}[/] pending, "
        f"database [cyan]{runner.db_path}[/]"
    )


@cli.command()
@click.option("--dry-run", is_flag=True, help="List pending migrations without applying.")
@click.pass_context
def migrate(ctx: click.Context, dry_run: bool) -> None:
    """Apply all pending migrations."""

    runner = _runner(ctx)
    try:
        with runner.connect() as conn:
            pending = runner.pending(conn)
            if dry_run:
                if not pending:
                    console.print("[green]Up to date.[/] No pending migrations.")
                    return
                console.print(f"[bold]{len(pending)}[/] pending migration(s):")
                for migration in pending:
                    console.print(f"  [magenta]{migration.version}[/] {migration.name}")
                return

            applied = runner.migrate(conn)
    except MigrationError as exc:
        err_console.print(f"[bold red]Error:[/] {exc}")
        raise SystemExit(1)

    if not applied:
        console.print("[green]Up to date.[/] No pending migrations.")
        return
    for migration in applied:
        console.print(f"[green]✓[/] applied [cyan]{migration.version}[/] {migration.name}")
    console.print(f"[bold green]Done.[/] Applied {len(applied)} migration(s).")


@cli.command()
@click.pass_context
def seed(ctx: click.Context) -> None:
    """Execute the SQL files in the seeds directory."""

    settings = ctx.obj["settings"]
    runner = _runner(ctx)
    try:
        with runner.connect() as conn:
            executed = runner.seed(conn, settings.seeds_dir)
    except MigrationError as exc:
        err_console.print(f"[bold red]Error:[/] {exc}")
        raise SystemExit(1)

    if not executed:
        console.print("[yellow]No seed files found.[/]")
        return
    for path in executed:
        console.print(f"[green]✓[/] seeded [cyan]{path.name}[/]")
    console.print(f"[bold green]Done.[/] Executed {len(executed)} seed file(s).")


@cli.command()
@click.argument("sql")
@click.pass_context
def query(ctx: click.Context, sql: str) -> None:
    """Run a read-only SQL query and print the results as a table."""

    runner = _runner(ctx)
    try:
        with runner.connect() as conn:
            cursor = conn.execute(sql)
            rows = cursor.fetchall()
            columns = [d[0] for d in cursor.description] if cursor.description else []
    except sqlite3.Error as exc:
        err_console.print(f"[bold red]SQL error:[/] {exc}")
        raise SystemExit(1)

    if not columns:
        console.print("[green]OK[/] (no rows returned)")
        return

    table = Table(show_lines=False)
    for column in columns:
        table.add_column(str(column), style="white")
    for row in rows:
        table.add_row(*[("—" if row[c] is None else str(row[c])) for c in columns])
    console.print(table)
    console.print(f"[dim]{len(rows)} row(s)[/]")


def main() -> None:
    try:
        cli(obj={})
    except KeyboardInterrupt:  # pragma: no cover
        err_console.print("[red]Interrupted.[/]")
        sys.exit(130)


if __name__ == "__main__":  # pragma: no cover
    main()

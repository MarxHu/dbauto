"""Configuration resolution for dbauto.

Settings are resolved with the following precedence (highest first):

1. Explicit CLI options.
2. Environment variables (``DBAUTO_DATABASE_URL``, ``DBAUTO_MIGRATIONS_DIR``,
   ``DBAUTO_SEEDS_DIR``).
3. Built-in defaults.

Keeping this logic in one place makes the CLI thin and keeps the behaviour easy
to unit test.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

DEFAULT_DATABASE_URL = "sqlite:///dbauto.db"
DEFAULT_MIGRATIONS_DIR = "migrations"
DEFAULT_SEEDS_DIR = "seeds"

ENV_DATABASE_URL = "DBAUTO_DATABASE_URL"
ENV_MIGRATIONS_DIR = "DBAUTO_MIGRATIONS_DIR"
ENV_SEEDS_DIR = "DBAUTO_SEEDS_DIR"


@dataclass(frozen=True)
class Settings:
    """Resolved runtime settings for a dbauto invocation."""

    database_url: str
    migrations_dir: str
    seeds_dir: str


def resolve_settings(
    database_url: str | None = None,
    migrations_dir: str | None = None,
    seeds_dir: str | None = None,
    environ: dict[str, str] | None = None,
) -> Settings:
    """Merge CLI options, environment variables, and defaults into ``Settings``."""

    env = os.environ if environ is None else environ
    return Settings(
        database_url=database_url
        or env.get(ENV_DATABASE_URL)
        or DEFAULT_DATABASE_URL,
        migrations_dir=migrations_dir
        or env.get(ENV_MIGRATIONS_DIR)
        or DEFAULT_MIGRATIONS_DIR,
        seeds_dir=seeds_dir or env.get(ENV_SEEDS_DIR) or DEFAULT_SEEDS_DIR,
    )

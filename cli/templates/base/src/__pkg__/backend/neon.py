"""Neon Serverless Postgres integration (see goal.md §3).

Neon connection setup. Two endpoints, by purpose:

  - DATABASE_URL         → Neon **pooled** endpoint (PgBouncer, transaction mode).
                           Used for app request traffic.
  - DATABASE_URL_DIRECT  → Neon **direct** endpoint. Used by Alembic/migrations
                           and anything needing session state (SET, LISTEN/NOTIFY,
                           session advisory locks, SQL-level PREPARE/DEALLOCATE).

Resilience: Neon computes scale to zero (cold start on first query after idle)
and the container can sleep, so connections may be dropped. We use a bounded
pool, pool_pre_ping, and a short recycle so stale/cold connections are healed.
"""

from __future__ import annotations

import os
from collections.abc import Generator
from contextlib import asynccontextmanager
from typing import Annotated, AsyncGenerator, TypeAlias

from fastapi import Depends, FastAPI, Request
from sqlalchemy import Engine, create_engine, text
from sqlmodel import Session, SQLModel

from .config import logger, settings


def _engine_kwargs() -> dict:
    return {
        # The pooler multiplexes, so keep the app-side pool small.
        "pool_size": 5,
        "max_overflow": 5,
        "pool_pre_ping": True,          # heal connections dropped by scale-to-zero
        "pool_recycle": 300,            # recycle well under Neon idle timeout
        "pool_timeout": 10,
        "connect_args": {"sslmode": "require"},
    }


def create_db_engine() -> Engine:
    """App-traffic engine over the Neon pooled endpoint."""
    url = settings.database_url
    if not url:
        raise RuntimeError("DATABASE_URL is not set")
    logger.info("Creating Neon engine (pooled endpoint)")
    return create_engine(url, **_engine_kwargs())


def create_direct_engine() -> Engine:
    """Direct-endpoint engine for migrations / session-state operations."""
    url = settings.database_url_direct or settings.database_url
    if not url:
        raise RuntimeError("DATABASE_URL_DIRECT / DATABASE_URL is not set")
    logger.info("Creating Neon engine (direct endpoint)")
    return create_engine(url, pool_pre_ping=True, connect_args={"sslmode": "require"})


def validate_db(engine: Engine) -> None:
    """Tolerate one cold-start retry, then fail loudly."""
    import time

    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            with Session(engine) as session:
                session.connection().execute(text("SELECT 1"))
            logger.info("Neon connection validated")
            return
        except Exception as exc:  # noqa: BLE001 — surface after retries
            last_exc = exc
            wait = 0.5 * (attempt + 1)
            logger.warning("DB validate attempt %d failed (%s); retrying in %.1fs", attempt + 1, exc, wait)
            time.sleep(wait)
    raise ConnectionError(f"Failed to connect to Neon: {last_exc}")


def initialize_models(engine: Engine) -> None:
    """v1 schema bootstrap. Production schema changes go through Alembic (direct endpoint)."""
    logger.info("Initializing models (SQLModel.metadata.create_all)")
    SQLModel.metadata.create_all(engine)


@asynccontextmanager
async def db_lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    # Build-mode import must not touch the network (see goal.md §4 codegen contract).
    if os.environ.get("AKM_OPENAPI_BUILD") == "1":
        logger.info("AKM_OPENAPI_BUILD=1 — skipping DB init")
        app.state.engine = None
        yield
        return

    engine = create_db_engine()
    validate_db(engine)
    initialize_models(engine)
    app.state.engine = engine
    try:
        yield
    finally:
        engine.dispose()


def _session(request: Request) -> Generator[Session, None, None]:
    engine = request.app.state.engine
    if engine is None:
        raise RuntimeError("DB engine unavailable (build mode?)")
    with Session(bind=engine) as session:
        yield session


DbSession: TypeAlias = Annotated[Session, Depends(_session)]

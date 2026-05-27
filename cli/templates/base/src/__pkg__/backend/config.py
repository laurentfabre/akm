"""App configuration & logging."""

from __future__ import annotations

import logging

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("akm")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    # Neon endpoints (see neon.py).
    database_url: str = Field(default="", validation_alias="DATABASE_URL")
    database_url_direct: str = Field(default="", validation_alias="DATABASE_URL_DIRECT")

    # Shared HMAC key for the internal X-Akm-Identity JWT (see identity.py).
    internal_jwt_key: str = Field(default="", validation_alias="AKM_INTERNAL_JWT_KEY")


settings = Settings()

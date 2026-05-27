"""Identity dependency — validate the internal X-Akm-Identity JWT (see goal.md §4.5).

The container trusts EXACTLY ONE thing: the HS256 X-Akm-Identity assertion minted
by the Worker (or, in dev, the akm proxy) and signed with AKM_INTERNAL_JWT_KEY.
Client-supplied identity headers are never trusted (the Worker strips them).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from base64 import urlsafe_b64decode
from dataclasses import dataclass
from typing import Annotated, Literal, TypeAlias

from fastapi import Depends, Header, HTTPException

from .config import settings

ISS = "akm-worker"
AUD = "akm-backend"


@dataclass(frozen=True)
class Principal:
    sub: str
    email: str | None
    kind: Literal["user", "service"]

    @property
    def is_user(self) -> bool:
        return self.kind == "user"


def _b64url_decode(seg: str) -> bytes:
    return urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def _verify(token: str, key: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("malformed token")
    header_b64, payload_b64, sig_b64 = parts

    header = json.loads(_b64url_decode(header_b64))
    if header.get("alg") != "HS256":
        raise ValueError("unexpected alg")

    signing_input = f"{header_b64}.{payload_b64}".encode()
    expected = hmac.new(key.encode(), signing_input, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, _b64url_decode(sig_b64)):
        raise ValueError("bad signature")

    claims = json.loads(_b64url_decode(payload_b64))
    now = int(time.time())
    if claims.get("iss") != ISS:
        raise ValueError("bad iss")
    if claims.get("aud") != AUD:
        raise ValueError("bad aud")
    if "exp" in claims and claims["exp"] < now:
        raise ValueError("expired")
    if "nbf" in claims and claims["nbf"] > now + 60:
        raise ValueError("not yet valid")
    if claims.get("kind") not in ("user", "service"):
        raise ValueError("bad kind")
    return claims


def get_principal(
    x_akm_identity: Annotated[str | None, Header()] = None,
) -> Principal:
    if not x_akm_identity:
        raise HTTPException(status_code=401, detail="missing identity")
    if not settings.internal_jwt_key:
        raise HTTPException(status_code=500, detail="AKM_INTERNAL_JWT_KEY not configured")
    try:
        claims = _verify(x_akm_identity, settings.internal_jwt_key)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail=f"invalid identity: {exc}") from exc
    return Principal(sub=claims["sub"], email=claims.get("email"), kind=claims["kind"])


CurrentPrincipal: TypeAlias = Annotated[Principal, Depends(get_principal)]

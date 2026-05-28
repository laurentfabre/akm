"""Identity dependency — validate the internal X-Akm-Identity JWT (see goal.md §4.5).

The container trusts EXACTLY ONE thing: the HS256 X-Akm-Identity assertion minted
by the Worker (or, in dev, the akm proxy) and signed with AKM_INTERNAL_JWT_KEY.
Client-supplied identity headers are never trusted (the Worker strips them).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import time
from base64 import urlsafe_b64decode
from dataclasses import dataclass
from typing import Annotated, Literal, TypeAlias

from fastapi import Depends, Header, HTTPException

from .config import settings

ISS = "akm-worker"
AUD = "akm-backend"

# Internal tokens are short-lived: both minters (Worker auth.ts, Zig jwt.zig)
# emit `exp = iat + 120`. The backend enforces this window itself so a leaked or
# misconfigured-minter token can't claim a long lifetime (defense in depth).
MAX_TTL_SECONDS = 120
CLOCK_SKEW_SECONDS = 60
# A short HMAC key makes forgery cheap; require real key material (a hex/base64
# 32-byte secret is ≥32 chars). The minters use 64-hex-char keys.
MIN_KEY_LEN = 32


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


def _reject_constant(_: str) -> float:
    # json.loads accepts non-standard NaN/Infinity by default. Every comparison
    # with NaN is False, so `iat: NaN` / `exp: NaN` would slip past the expiry
    # and replay-window checks below — reject them at parse time.
    raise ValueError("non-finite number in token")


def _loads_strict(data: bytes) -> object:
    return json.loads(data, parse_constant=_reject_constant)


def _numeric_date(claims: dict, name: str) -> float:
    """A mandatory, finite, non-bool NumericDate claim (e.g. iat/nbf/exp)."""
    v = claims.get(name)
    if not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v):
        raise ValueError(f"missing or invalid {name}")
    return v


def _verify(token: str, key: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("malformed token")
    header_b64, payload_b64, sig_b64 = parts

    # Decode defensively: bad base64 / JSON / non-object payloads must surface as
    # ValueError (→ 401), never an uncaught error (→ 500). binascii.Error and
    # json.JSONDecodeError are both ValueError subclasses.
    try:
        header = _loads_strict(_b64url_decode(header_b64))
        sig = _b64url_decode(sig_b64)
    except ValueError as exc:
        raise ValueError("malformed token") from exc
    if not isinstance(header, dict):
        raise ValueError("malformed header")
    if header.get("alg") != "HS256":
        raise ValueError("unexpected alg")

    signing_input = f"{header_b64}.{payload_b64}".encode()
    expected = hmac.new(key.encode(), signing_input, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, sig):
        raise ValueError("bad signature")

    try:
        claims = _loads_strict(_b64url_decode(payload_b64))
    except ValueError as exc:
        raise ValueError("malformed token") from exc
    if not isinstance(claims, dict):
        raise ValueError("malformed claims")
    now = int(time.time())
    if claims.get("iss") != ISS:
        raise ValueError("bad iss")
    if claims.get("aud") != AUD:
        raise ValueError("bad aud")
    # iat/nbf/exp are all mandatory, finite, non-bool NumericDates (the minters
    # emit all three). Using a strict helper + finite check defeats the NaN trick
    # where every comparison is False and slips past the expiry/window checks.
    iat = _numeric_date(claims, "iat")
    if iat > now + CLOCK_SKEW_SECONDS:
        raise ValueError("iat in the future")
    exp = _numeric_date(claims, "exp")
    if exp <= now:
        raise ValueError("expired exp")
    # Enforce the replay window at the trust boundary: even a validly-signed token
    # may not claim a lifetime longer than the contract (≤120s + skew).
    if exp - iat > MAX_TTL_SECONDS + CLOCK_SKEW_SECONDS:
        raise ValueError("token lifetime too long")
    nbf = _numeric_date(claims, "nbf")
    if nbf > now + CLOCK_SKEW_SECONDS:
        raise ValueError("not yet valid")
    if claims.get("kind") not in ("user", "service"):
        raise ValueError("bad kind")
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise ValueError("missing or invalid sub")
    email = claims.get("email")
    if email is not None and not isinstance(email, str):
        raise ValueError("invalid email")
    return claims


def get_principal(
    x_akm_identity: Annotated[str | None, Header()] = None,
) -> Principal:
    if not x_akm_identity:
        raise HTTPException(status_code=401, detail="missing identity")
    if not settings.internal_jwt_key or len(settings.internal_jwt_key) < MIN_KEY_LEN:
        raise HTTPException(status_code=500, detail="AKM_INTERNAL_JWT_KEY missing or too short")
    try:
        claims = _verify(x_akm_identity, settings.internal_jwt_key)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail=f"invalid identity: {exc}") from exc
    return Principal(sub=claims["sub"], email=claims.get("email"), kind=claims["kind"])


CurrentPrincipal: TypeAlias = Annotated[Principal, Depends(get_principal)]

// auth.ts — the single identity authority (see goal.md §4.5).
//
// Order is mandatory:
//   1. VALIDATE the incoming Cloudflare Access JWT (Cf-Access-Jwt-Assertion)
//      against the team JWKS: signature, aud, iss, exp/nbf.
//   2. Only then build a sanitized downstream request: strip every client-supplied
//      identity header, attach exactly one minted internal assertion.
//   3. MINT one short-lived X-Akm-Identity (HS256) the container alone trusts.
//
// The container never trusts client headers — only X-Akm-Identity.

export interface Env {
  // Cloudflare Access team domain, e.g. "myteam" for myteam.cloudflareaccess.com
  CF_ACCESS_TEAM_DOMAIN: string;
  // The Access application AUD tag (audience) this Worker is protected by.
  CF_ACCESS_AUD: string;
  // Shared HMAC secret for the internal X-Akm-Identity JWT (wrangler secret).
  AKM_INTERNAL_JWT_KEY: string;
}

export interface Identity {
  sub: string;
  email: string | null;
  kind: "user" | "service";
}

const enc = new TextEncoder();

// ── public API ───────────────────────────────────────────────────────────

/** Validate the Access JWT and return the caller identity, or null if invalid. */
export async function authenticate(req: Request, env: Env): Promise<Identity | null> {
  const token =
    req.headers.get("Cf-Access-Jwt-Assertion") ??
    cookie(req, "CF_Authorization");
  if (!token) return null;

  const claims = await verifyAccessJwt(token, env);
  if (!claims) return null;

  // Service tokens have an empty `sub`; derive a stable service principal.
  const isService = !claims.sub || claims.sub.length === 0;
  if (isService) {
    const cn = (claims.common_name as string) || (claims.azp as string) || "unknown";
    return { sub: `svc:${cn}`, email: null, kind: "service" };
  }
  return {
    sub: claims.sub as string,
    email: (claims.email as string) ?? null,
    kind: "user",
  };
}

/**
 * Return a new request to forward to the container: all incoming identity
 * headers stripped, exactly one minted X-Akm-Identity attached.
 */
export async function sanitizeAndMint(req: Request, env: Env, id: Identity): Promise<Request> {
  const headers = new Headers(req.headers);
  // Strip everything spoofable.
  for (const h of [...headers.keys()]) {
    const l = h.toLowerCase();
    if (l.startsWith("cf-access-") || l.startsWith("x-forwarded-") || l.startsWith("x-akm-")) {
      headers.delete(h);
    }
  }
  headers.set("X-Akm-Identity", await mintInternalJwt(id, env));
  return new Request(req, { headers });
}

// ── Access JWT validation ──────────────────────────────────────────────────

interface Jwk {
  kid: string;
  kty: string;
  n: string;
  e: string;
  alg?: string;
}
let jwksCache: { keys: Jwk[]; fetchedAt: number } | null = null;

async function getJwks(env: Env): Promise<Jwk[]> {
  const now = Date.now();
  if (jwksCache && now - jwksCache.fetchedAt < 60 * 60 * 1000) return jwksCache.keys;
  const url = `https://${env.CF_ACCESS_TEAM_DOMAIN}.cloudflareaccess.com/cdn-cgi/access/certs`;
  const res = await fetch(url, { cf: { cacheTtl: 3600 } });
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys: Jwk[] };
  jwksCache = { keys: body.keys, fetchedAt: now };
  return body.keys;
}

async function verifyAccessJwt(token: string, env: Env): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  let header: { kid?: string; alg?: string };
  let claims: Record<string, unknown>;
  try {
    header = JSON.parse(b64urlToString(h));
    claims = JSON.parse(b64urlToString(p));
  } catch {
    return null;
  }
  if (header.alg !== "RS256" || !header.kid) return null;

  const jwk = (await getJwks(env)).find((k) => k.kid === header.kid);
  if (!jwk) return null;

  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64urlToBytes(s),
    enc.encode(`${h}.${p}`),
  );
  if (!ok) return null;

  // Claim checks.
  const nowSec = Math.floor(Date.now() / 1000);
  if (typeof claims.exp === "number" && claims.exp < nowSec) return null;
  if (typeof claims.nbf === "number" && claims.nbf > nowSec + 60) return null;
  const aud = claims.aud;
  const audOk = Array.isArray(aud) ? aud.includes(env.CF_ACCESS_AUD) : aud === env.CF_ACCESS_AUD;
  if (!audOk) return null;
  const expectedIss = `https://${env.CF_ACCESS_TEAM_DOMAIN}.cloudflareaccess.com`;
  if (claims.iss !== expectedIss) return null;

  return claims;
}

// ── internal X-Akm-Identity minting (HS256) ─────────────────────────────────

async function mintInternalJwt(id: Identity, env: Env): Promise<string> {
  const nowSec = Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload: Record<string, unknown> = {
    iss: "akm-worker",
    aud: "akm-backend",
    iat: nowSec,
    nbf: nowSec,
    exp: nowSec + 120, // ≤120s TTL
    sub: id.sub,
    kind: id.kind,
  };
  if (id.kind === "user" && id.email) payload.email = id.email;

  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(env.AKM_INTERNAL_JWT_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(signingInput));
  return `${signingInput}.${b64urlBytes(new Uint8Array(sig))}`;
}

// ── base64url helpers ────────────────────────────────────────────────────────

function b64url(s: string): string {
  return b64urlBytes(enc.encode(s));
}
function b64urlBytes(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64urlToString(s: string): string {
  return new TextDecoder().decode(b64urlToBytes(s));
}
function cookie(req: Request, name: string): string | null {
  const raw = req.headers.get("Cookie");
  if (!raw) return null;
  for (const part of raw.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

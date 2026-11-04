import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

const STATE_TTL = 10 * 60;
const SESSION_TTL = 60 * 60 * 8;
const b64 = (value: string | Buffer) => Buffer.from(value).toString("base64url");
const sign = (value: string, secret: string) => createHmac("sha256", secret).update(value).digest("base64url");

export function authConfigured() {
  return Boolean(process.env.DISCORD_CLIENT_ID && process.env.DISCORD_CLIENT_SECRET
    && process.env.DISCORD_REDIRECT_URI && process.env.SESSION_SECRET
    && process.env.SESSION_SECRET.length >= 32);
}

export function makeState(secret: string, now = Math.floor(Date.now() / 1000)) {
  const nonce = randomBytes(24).toString("base64url");
  const payload = `${now}.${nonce}`;
  return `${b64(payload)}.${sign(payload, secret)}`;
}

export function verifyState(state: string, cookie: string, secret: string, now = Math.floor(Date.now() / 1000)) {
  if (!state || !cookie || state.length > 300 || cookie.length > 300 || state !== cookie) return false;
  const [encoded, signature, extra] = state.split(".");
  if (!encoded || !signature || extra) return false;
  let payload: string;
  try { payload = Buffer.from(encoded, "base64url").toString("utf8"); } catch { return false; }
  const expected = sign(payload, secret);
  const left = Buffer.from(signature);
  const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) return false;
  const [issued, nonce, extraPayload] = payload.split(".");
  const issuedAt = Number(issued);
  return !extraPayload && Boolean(nonce) && Number.isInteger(issuedAt)
    && issuedAt <= now && now - issuedAt <= STATE_TTL;
}

export type MollySession = { id: string; username: string; avatar: string | null; exp: number; csrf: string };

export function createSession(user: { id: string; username: string; avatar: string | null }, secret: string, now = Math.floor(Date.now() / 1000)) {
  if (!/^\d{5,25}$/.test(user.id) || typeof user.username !== "string" || user.username.length > 100) throw new Error("invalid_user");
  const session: MollySession = { ...user, exp: now + SESSION_TTL, csrf: randomBytes(24).toString("base64url") };
  const encoded = b64(JSON.stringify(session));
  return `${encoded}.${sign(encoded, secret)}`;
}

export function readSession(value: string | undefined, secret: string, now = Math.floor(Date.now() / 1000)): MollySession | null {
  if (!value || value.length > 2048) return null;
  const [encoded, signature, extra] = value.split(".");
  if (!encoded || !signature || extra) return null;
  const expected = sign(encoded, secret);
  const left = Buffer.from(signature);
  const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) return null;
  try {
    const session = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as MollySession;
    if (!/^\d{5,25}$/.test(session.id) || typeof session.username !== "string" || !Number.isInteger(session.exp)
      || session.exp <= now || typeof session.csrf !== "string" || session.csrf.length < 20) return null;
    return session;
  } catch { return null; }
}

export function verifyCsrf(expected: string, supplied: unknown) {
  if (typeof supplied !== "string" || supplied.length > 128) return false;
  const left = Buffer.from(expected);
  const right = Buffer.from(supplied);
  return left.length === right.length && timingSafeEqual(left, right);
}

export const sessionMaxAge = SESSION_TTL;
export const stateMaxAge = STATE_TTL;

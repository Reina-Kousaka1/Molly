import { NextRequest, NextResponse } from "next/server";
import { authConfigured, createSession, sessionMaxAge, verifyState } from "@/lib/auth";

export const runtime = "nodejs";

function fail(request: NextRequest, reason: string, status = 400) {
  const response = NextResponse.redirect(new URL(`/dashboard?auth=${reason}`, request.url));
  response.cookies.delete("molly_oauth_state");
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("Referrer-Policy", "no-referrer");
  return status === 400 ? response : NextResponse.json({ error: reason }, { status });
}

export async function GET(request: NextRequest) {
  if (!authConfigured()) return fail(request, "not_configured", 503);
  const code = request.nextUrl.searchParams.get("code") || "";
  const state = request.nextUrl.searchParams.get("state") || "";
  const cookieState = request.cookies.get("molly_oauth_state")?.value || "";
  const secret = process.env.SESSION_SECRET!;
  if (!code || code.length > 2048 || !verifyState(state, cookieState, secret)) return fail(request, "state_invalid");

  try {
    const tokenResponse = await fetch("https://discord.com/api/oauth2/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams({ client_id: process.env.DISCORD_CLIENT_ID!, client_secret: process.env.DISCORD_CLIENT_SECRET!, grant_type: "authorization_code", code, redirect_uri: process.env.DISCORD_REDIRECT_URI! }),
      cache: "no-store", signal: AbortSignal.timeout(8000),
    });
    if (!tokenResponse.ok) return fail(request, "exchange_failed");
    const token = await tokenResponse.json() as { access_token?: string; token_type?: string; scope?: string };
    if (typeof token.access_token !== "string" || token.token_type?.toLowerCase() !== "bearer" || !token.scope?.split(" ").includes("identify")) return fail(request, "exchange_failed");
    const profileResponse = await fetch("https://discord.com/api/users/@me", {
      headers: { Authorization: `Bearer ${token.access_token}`, Accept: "application/json" }, cache: "no-store", signal: AbortSignal.timeout(8000),
    });
    if (!profileResponse.ok) return fail(request, "profile_failed");
    const profile = await profileResponse.json() as { id?: string; username?: string; avatar?: string | null };
    if (typeof profile.id !== "string" || typeof profile.username !== "string") return fail(request, "profile_failed");
    const session = createSession({ id: profile.id, username: profile.username.slice(0, 100), avatar: typeof profile.avatar === "string" ? profile.avatar.slice(0, 100) : null }, secret);
    const response = NextResponse.redirect(new URL("/dashboard?auth=success", request.url));
    response.cookies.delete("molly_oauth_state");
    response.cookies.set("molly_session", session, { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: sessionMaxAge });
    response.headers.set("Cache-Control", "no-store");
    response.headers.set("Referrer-Policy", "no-referrer");
    return response;
  } catch {
    // Do not log OAuth payloads, authorization codes, or Discord tokens.
    return fail(request, "provider_unavailable");
  }
}

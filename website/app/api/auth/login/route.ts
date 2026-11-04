import { NextResponse } from "next/server";
import { authConfigured, makeState, stateMaxAge } from "@/lib/auth";

export const runtime = "nodejs";

export async function GET() {
  if (!authConfigured()) return NextResponse.json({ error: "discord_oauth_not_configured" }, { status: 503 });
  const clientId = process.env.DISCORD_CLIENT_ID!;
  const redirectUri = process.env.DISCORD_REDIRECT_URI!;
  const secret = process.env.SESSION_SECRET!;
  try {
    const callback = new URL(redirectUri);
    if (callback.protocol !== "https:" && callback.hostname !== "localhost") throw new Error("invalid_callback");
    const state = makeState(secret);
    const authorize = new URL("https://discord.com/oauth2/authorize");
    authorize.searchParams.set("client_id", clientId);
    authorize.searchParams.set("redirect_uri", redirectUri);
    authorize.searchParams.set("response_type", "code");
    authorize.searchParams.set("scope", "identify");
    authorize.searchParams.set("state", state);
    const response = NextResponse.redirect(authorize);
    response.cookies.set("molly_oauth_state", state, { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/api/auth", maxAge: stateMaxAge });
    return response;
  } catch {
    return NextResponse.json({ error: "discord_oauth_configuration_invalid" }, { status: 503 });
  }
}

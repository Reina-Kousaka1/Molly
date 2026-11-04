import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { GET as callback } from "../app/api/auth/callback/route";
import { GET as login } from "../app/api/auth/login/route";
import { POST as logout } from "../app/api/auth/logout/route";
import { GET as guilds } from "../app/api/dashboard/guilds/route";
import { createSession, makeState } from "../lib/auth";

const secret = "test-only-session-secret-with-at-least-thirty-two-characters";
const original = { id: process.env.DISCORD_CLIENT_ID, client: process.env.DISCORD_CLIENT_SECRET, redirect: process.env.DISCORD_REDIRECT_URI, secret: process.env.SESSION_SECRET, node: process.env.NODE_ENV };
const env = process.env as Record<string, string | undefined>;

function configured() {
  env.DISCORD_CLIENT_ID = "test-client-id";
  env.DISCORD_CLIENT_SECRET = "test-client-secret";
  env.DISCORD_REDIRECT_URI = "https://molly.example/api/auth/callback";
  env.SESSION_SECRET = secret;
  env.NODE_ENV = "production";
}

afterEach(() => {
  if (original.id === undefined) delete env.DISCORD_CLIENT_ID; else env.DISCORD_CLIENT_ID = original.id;
  if (original.client === undefined) delete env.DISCORD_CLIENT_SECRET; else env.DISCORD_CLIENT_SECRET = original.client;
  if (original.redirect === undefined) delete env.DISCORD_REDIRECT_URI; else env.DISCORD_REDIRECT_URI = original.redirect;
  if (original.secret === undefined) delete env.SESSION_SECRET; else env.SESSION_SECRET = original.secret;
  if (original.node === undefined) delete env.NODE_ENV; else env.NODE_ENV = original.node;
  vi.unstubAllGlobals();
});

describe("Discord OAuth route security", () => {
  it("starts the minimal identify-only flow with secure state cookie", async () => {
    configured();
    const response = await login();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toContain("scope=identify");
    expect(response.headers.get("location")).toContain("response_type=code");
    const cookie = response.headers.get("set-cookie") || "";
    expect(cookie).toContain("molly_oauth_state=");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
    expect(cookie).toContain("SameSite=lax");
  });

  it("rejects invalid callback state before contacting Discord", async () => {
    configured();
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const request = new NextRequest("https://molly.example/api/auth/callback?code=untrusted&state=wrong");
    const response = await callback(request);
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toContain("auth=state_invalid");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("exchanges code server-side and only issues a signed identity cookie", async () => {
    configured();
    const state = makeState(secret);
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ access_token: "test-provider-token", token_type: "Bearer", scope: "identify" }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ id: "12345678901234567", username: "bestie", avatar: null }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const request = new NextRequest(`https://molly.example/api/auth/callback?code=one-time-code&state=${encodeURIComponent(state)}`, { headers: { Cookie: `molly_oauth_state=${state}` } });
    const response = await callback(request);
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toContain("/dashboard?auth=success");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const profileHeaders = fetchMock.mock.calls[1][1]?.headers as Record<string, string>;
    expect(profileHeaders.Authorization).toBe("Bearer test-provider-token");
    const cookie = response.headers.get("set-cookie") || "";
    expect(cookie).toContain("molly_session=");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
    expect(cookie).not.toContain("test-provider-token");
    expect(cookie).not.toContain("access_token");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("requires same-origin and matching CSRF token to log out", async () => {
    configured();
    const session = createSession({ id: "12345678901234567", username: "bestie", avatar: null }, secret);
    const csrf = JSON.parse(Buffer.from(session.split(".")[0], "base64url").toString("utf8")).csrf as string;
    const request = new NextRequest("https://molly.example/api/auth/logout", {
      method: "POST", headers: { Origin: "https://molly.example", Cookie: `molly_session=${session}`, "Content-Type": "application/json" }, body: JSON.stringify({ csrf }),
    });
    const response = await logout(request);
    expect(response.status).toBe(200);
    expect(response.headers.get("set-cookie")).toContain("molly_session=;");

    const rejected = new NextRequest("https://molly.example/api/auth/logout", {
      method: "POST", headers: { Origin: "https://attacker.example", Cookie: `molly_session=${session}`, "Content-Type": "application/json" }, body: JSON.stringify({ csrf }),
    });
    expect((await logout(rejected)).status).toBe(403);
  });

  it("never returns guild data, even for an authenticated account", async () => {
    configured();
    const session = createSession({ id: "12345678901234567", username: "bestie", avatar: null }, secret);
    for (const guildId of ["11111111111111111", "22222222222222222"]) {
      const request = new NextRequest(`https://molly.example/api/dashboard/guilds?guild=${guildId}`, { headers: { Cookie: `molly_session=${session}` } });
      const response = await guilds(request);
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "bot_dashboard_api_unavailable", guilds: [] });
    }
  });
});

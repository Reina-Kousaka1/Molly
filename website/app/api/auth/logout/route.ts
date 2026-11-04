import { NextRequest, NextResponse } from "next/server";
import { readSession, verifyCsrf } from "@/lib/auth";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  const expectedOrigin = new URL(request.url).origin;
  if (request.headers.get("origin") !== expectedOrigin) return NextResponse.json({ error: "origin_invalid" }, { status: 403 });
  let body: { csrf?: unknown };
  try { body = await request.json() as { csrf?: unknown }; } catch { return NextResponse.json({ error: "request_invalid" }, { status: 400 }); }
  const session = readSession(request.cookies.get("molly_session")?.value, process.env.SESSION_SECRET || "");
  if (!session || !verifyCsrf(session.csrf, body.csrf)) return NextResponse.json({ error: "csrf_invalid" }, { status: 403 });
  const response = NextResponse.json({ ok: true });
  response.cookies.delete("molly_session");
  response.headers.set("Cache-Control", "no-store");
  return response;
}

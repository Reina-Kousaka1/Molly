import { NextRequest, NextResponse } from "next/server";
import { readSession } from "@/lib/auth";

export const runtime = "nodejs";
export async function GET(request: NextRequest) {
  const session = readSession(request.cookies.get("molly_session")?.value, process.env.SESSION_SECRET || "");
  if (!session) return NextResponse.json({ error: "unauthorized" }, { status: 401, headers: { "Cache-Control": "no-store" } });
  return NextResponse.json({ error: "bot_dashboard_api_unavailable", guilds: [] }, { status: 503, headers: { "Cache-Control": "no-store" } });
}

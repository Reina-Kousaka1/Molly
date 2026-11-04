"use client";

import { useRouter } from "next/navigation";

export function DashboardLogin({ enabled, name, csrf }: { enabled: boolean; name?: string; csrf?: string }) {
  const router = useRouter();
  if (name) return <div className="signed-in-actions"><p className="signed-in-note">Signed in as <strong>{name}</strong>. Guild settings remain unavailable until Molly’s authenticated dashboard API exists.</p><button className="text-link logout-button" onClick={async () => { const response = await fetch("/api/auth/logout", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ csrf }) }); if (response.ok) router.refresh(); }}>Sign out</button></div>;
  return enabled
    ? <a className="button button-primary" href="/api/auth/login">Continue with Discord <span aria-hidden="true">↗</span></a>
    : <button className="button button-disabled" disabled title="Discord OAuth is not configured">Discord login is not configured yet</button>;
}

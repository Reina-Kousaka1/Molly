import type { Metadata } from "next";
import { cookies } from "next/headers";
import { AvailabilityPill } from "@/components/availability-pill";
import { DashboardLogin } from "@/components/dashboard-login";
import { PageIntro } from "@/components/site-shell";
import { authConfigured, readSession } from "@/lib/auth";
export const metadata: Metadata = { title: "Server dashboard" };
export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const cookieStore = await cookies();
  const secret = process.env.SESSION_SECRET || "";
  const session = readSession(cookieStore.get("molly_session")?.value, secret);
  return <div className="page-container dashboard-page"><PageIntro eyebrow="your server, your settings" title="Dashboard, bestie." copy="Sign-in is only for identity. Guild selection and controls stay unavailable until Molly has a secure authenticated bot API." />
    <section className="dashboard-login card-surface"><div className="login-art">🎀<span>✦</span></div><div><span className="eyebrow">{session ? "you’re signed in" : "discord account"}</span><h2>{session ? `Hi, ${session.username}.` : "Come on in, cutie."}</h2><p>{session ? "Your identity is verified for this session. No Discord access token is stored in the browser or session cookie." : "Connect your Discord identity securely. Molly’s private configuration API is not connected yet, so this will not expose or change any server settings."}<br/><small>OAuth permissions requested: identify only.</small></p><DashboardLogin enabled={authConfigured()} name={session?.username} csrf={session?.csrf} /></div></section>
    <div className="dashboard-grid"><section className="dashboard-card"><div className="dashboard-card-heading"><div><span className="eyebrow">servers</span><h2>Your server spaces</h2></div><AvailabilityPill /></div><p>No server list is shown because Molly does not currently expose a trusted endpoint confirming which servers have her installed. This protects against showing unsupported guilds.</p><button className="button button-disabled" disabled>Server list unavailable</button></section>
      <section className="dashboard-card"><div className="dashboard-card-heading"><div><span className="eyebrow">bot connection</span><h2>Runtime status</h2></div><AvailabilityPill /></div><p>There is no public health or status API. We won’t guess from this website’s uptime.</p><span className="disabled-line">Live bot status · not connected</span></section>
      <section className="dashboard-card"><div className="dashboard-card-heading"><div><span className="eyebrow">economy</span><h2>Economy controls</h2></div><AvailabilityPill /></div><p>Guild-specific balances, settings, and transaction histories remain in Molly’s bot storage. This website cannot read or mutate them.</p><span className="disabled-line">Settings · transaction history · disabled</span></section>
      <section className="dashboard-card"><div className="dashboard-card-heading"><div><span className="eyebrow">community & safety</span><h2>Moderation settings</h2></div><AvailabilityPill /></div><p>Logging, moderation, roles, and shop controls need a bot-side permission-checked API. No direct database access is exposed here.</p><span className="disabled-line">Configuration · audit history · disabled</span></section>
    </div><div className="integration-callout"><span>🫧</span><p><strong>What would make this dashboard live?</strong><br/>A narrowly scoped Molly API on the bot host, with authenticated per-guild requests, permission rechecks, an audit trail, and a defined availability model. SeaWorld and PreppyDB must remain private.</p></div>
  </div>;
}

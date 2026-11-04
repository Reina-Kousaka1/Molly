import type { Metadata } from "next";
import Link from "next/link";
import { PageIntro } from "@/components/site-shell";
export const metadata: Metadata = { title: "Support" };
export default function SupportPage() {
  return <div className="page-container"><PageIntro eyebrow="need a hand?" title="Support, sweetie." copy="Find Molly’s real commands and project information. Support contact details are intentionally not invented." /><section className="support-grid"><article className="support-card"><span>💬</span><h2>Need command help?</h2><p>Use Molly’s <code>/help</code> command in a server, or browse the verified list here.</p><Link href="/commands" className="text-link">Browse commands →</Link></article><article className="support-card"><span>🛠️</span><h2>Project support</h2><p>No public support address or invite link is configured on this site yet.</p><span className="disabled-line">Contact channel · not configured</span></article><article className="support-card"><span>🪙</span><h2>Virtual economy</h2><p>Coins, shop items, and resources are server-scoped virtual bot features. This website does not sell anything.</p><Link href="/shop" className="text-link">See the virtual catalog →</Link></article></section></div>;
}

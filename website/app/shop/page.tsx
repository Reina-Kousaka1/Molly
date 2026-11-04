import type { Metadata } from "next";
import { PageIntro } from "@/components/site-shell";
import { shopAvailability } from "@/lib/catalog";
export const metadata: Metadata = { title: "Molly's Beauty Shop" };
export default function ShopPage() {
  return <div className="page-container"><PageIntro eyebrow="a virtual boutique moodboard" title="Molly’s Beauty Shop." copy="A pink little page for future virtual treasures. The current Molly main branch does not yet have an in-bot item catalog, so no products or prices are shown." />
    <section className="shop-unavailable card-surface"><div className="shop-unavailable-art">🛍️<span>♡</span></div><div><span className="eyebrow">not connected · source checked</span><h2>Shop features aren’t live yet.</h2><p>{shopAvailability.reason} Molly’s existing economy supports balances, bank transfers, daily and weekly claims, work, payments, and transaction history. This site has no purchase flow.</p><span className="disabled-line">Items · prices · buying · inventory · unavailable</span></div></section>
    <div className="shop-note"><span>🪙</span><p><strong>Virtual only.</strong> When a real in-bot catalog exists, this page can show its source-defined items and currency label. No real products, payments, or shipping are offered here.</p></div>
  </div>;
}

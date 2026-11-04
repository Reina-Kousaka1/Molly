import Link from "next/link";

const links = [
  ["Meet Molly", "/meet-molly"], ["Commands", "/commands"], ["Beauty shop", "/shop"],
  ["GRWM & diary", "/diary"], ["Support", "/support"],
] as const;

export function SiteHeader() {
  return <header className="site-header"><Link className="brand" href="/" aria-label="Molly home"><span className="brand-bow">🎀</span><span>molly<span className="brand-dot">.</span></span></Link>
    <nav className="desktop-nav" aria-label="Main navigation">{links.map(([label, href]) => <Link href={href} key={href}>{label}</Link>)}</nav>
    <Link className="nav-cta" href="/dashboard">Dashboard <span aria-hidden="true">↗</span></Link>
    <details className="mobile-menu"><summary aria-label="Open navigation menu">☰</summary><nav aria-label="Mobile navigation">{links.map(([label, href]) => <Link href={href} key={href}>{label}</Link>)}<Link href="/dashboard">Dashboard</Link></nav></details>
  </header>;
}

export function SiteFooter() {
  return <footer className="site-footer"><div><Link className="brand" href="/"><span>🎀</span><span>molly<span className="brand-dot">.</span></span></Link><p>Your little preppy corner of Discord.</p></div>
    <div className="footer-links"><Link href="/support">Support</Link><Link href="/legal/privacy">Privacy</Link><Link href="/legal/terms">Terms</Link><Link href="/legal/imprint">Imprint</Link></div>
    <small>Fan-made visual style. Molly is an independent Discord bot project.</small>
  </footer>;
}

export function PageIntro({ eyebrow, title, copy }: { eyebrow: string; title: string; copy: string }) {
  return <div className="page-intro"><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p>{copy}</p></div>;
}

export function BowMark({ className = "" }: { className?: string }) {
  return <svg className={className} viewBox="0 0 180 120" role="img" aria-label="Pink ribbon bow"><defs><linearGradient id="bow" x1="0" x2="1"><stop stopColor="#ff80b5"/><stop offset="1" stopColor="#ff4fa3"/></linearGradient></defs><path d="M82 56C46 14 7 4 12 38c3 18 30 34 69 28-39 13-63 34-48 47 17 15 45-16 57-48" fill="url(#bow)"/><path d="M98 56c36-42 75-52 70-18-3 18-30 34-69 28 39 13 63 34 48 47-17 15-45-16-57-48" fill="url(#bow)"/><ellipse cx="90" cy="59" rx="14" ry="17" fill="#ffd6e8"/><path d="M87 72c-3 18-11 30-22 43 18-3 27-12 31-27 4 15 13 24 31 27-11-13-19-25-22-43" fill="#ff80b5"/></svg>;
}

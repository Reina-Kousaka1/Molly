import Link from "next/link";
import { AvailabilityPill } from "@/components/availability-pill";
import { BowMark } from "@/components/site-shell";

const features = [
  { icon: "💌", title: "Little server helper", text: "Useful moderation, community, music, and server utility commands—all from Molly’s real command set." },
  { icon: "🍓", title: "Virtual economy", text: "Daily and weekly rewards, work, banking, payments, and transaction history. No real purchases or payments." },
  { icon: "🫧", title: "Your server, your settings", text: "Guild-specific settings stay in Molly’s bot storage. This website won’t pretend to change them." },
];

export default function Home() {
  return <>
    <section className="hero section-pad"><div className="hero-copy"><span className="eyebrow"><span className="sparkle">✦</span> your discord bestie, with a bow</span><h1>Hi cutie, I’m <span>Molly.</span></h1><p className="hero-lede">Your server’s pink little helper for cozy community moments, virtual coins, and a sprinkle of main-character energy.</p><div className="hero-actions">{process.env.NEXT_PUBLIC_DISCORD_INVITE ? <a className="button button-primary" href={process.env.NEXT_PUBLIC_DISCORD_INVITE} target="_blank" rel="noreferrer">Invite Molly <span aria-hidden="true">↗</span></a> : <span className="button button-disabled" title="Invite URL has not been configured">Invite link unavailable</span>}<Link className="button button-soft" href="/dashboard">Explore dashboard</Link></div><div className="hero-meta"><AvailabilityPill>Live status unavailable</AvailabilityPill><span>Not connected to Molly’s runtime</span></div></div>
      <div className="hero-art" aria-label="Molly's pink and lavender moodboard illustration"><div className="art-glow"/><div className="polaroid polaroid-back"><span>glossy days</span><span className="polaroid-heart">♡</span></div><div className="polaroid polaroid-front"><div className="mascot-face"><BowMark className="mascot-bow"/><div className="eyes"><i/><i/></div><div className="blush blush-one"/><div className="blush blush-two"/><div className="smile"/></div><span className="polaroid-caption">Molly’s little corner</span></div><span className="float-sticker sticker-star">✦</span><span className="float-sticker sticker-heart">♡</span><span className="float-sticker sticker-cup">🥤</span><span className="float-sticker sticker-flower">✿</span><div className="ribbon-note">stay<br/>sweet!</div></div>
    </section>
    <div className="ticker" aria-label="Molly's moodboard"><span>STRAWBERRY MILK</span><b>✦</b><span>GLOSSY DAYS</span><b>♡</b><span>SOFT GIRL ENERGY</span><b>✦</b><span>PRETTY IN PINK</span><b>♡</b><span>STRAWBERRY MILK</span></div>
    <section className="section-pad intro-section"><div className="section-heading"><span className="eyebrow">a little bit of everything</span><h2>Sweet vibes, <em>useful buttons.</em></h2><p>Molly brings the sparkle and the practical stuff. Here’s what’s already in her codebase.</p></div><div className="feature-grid">{features.map((feature) => <article className="feature-card" key={feature.title}><div className="feature-icon">{feature.icon}</div><h3>{feature.title}</h3><p>{feature.text}</p><span className="card-arrow" aria-hidden="true">↗</span></article>)}</div></section>
    <section className="pink-banner section-pad"><div><span className="eyebrow">the cutest command closet</span><h2>Curious what Molly<br/>can really do?</h2><p>Every command on this page is checked against the actual Molly source.</p><Link className="button button-dark" href="/commands">Browse commands <span aria-hidden="true">→</span></Link></div><div className="banner-doodle" aria-hidden="true">🎀<span>⋆｡°✩</span></div></section>
    <section className="section-pad mini-links"><Link href="/meet-molly"><span>01 / THE GIRL</span><strong>Meet Molly</strong><i>↗</i></Link><Link href="/shop"><span>02 / VIRTUAL TREATS</span><strong>Beauty shop</strong><i>↗</i></Link><Link href="/diary"><span>03 / MOODBOARD</span><strong>GRWM & diary</strong><i>↗</i></Link></section>
  </>;
}

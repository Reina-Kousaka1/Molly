import type { Metadata } from "next";
import { PageIntro, BowMark } from "@/components/site-shell";
import { EasterEgg } from "@/components/easter-egg";
export const metadata: Metadata = { title: "Meet Molly" };
export default function MeetMolly() {
  return <div className="page-container"><PageIntro eyebrow="the girl behind the bow" title="Meet Molly, bestie." copy="A polished preppy moodboard for Molly, grounded in the real personality her bot code describes." />
    <section className="meet-layout"><div className="meet-art card-surface"><div className="meet-orbit">♡ <span>✦</span> ♡</div><BowMark className="meet-bow"/><div className="meet-sticker">M<br/>♡</div><p>your virtual bestie</p></div><div className="meet-copy"><span className="eyebrow">her in-code personality</span><h2>Community first.<br/><em>A little style.</em></h2><p>Molly’s default profile is a moderation and staff assistant: she helps keep the community organized, the team informed, and the details in order. The beauty, bows, and glossy pastels on this site are its visual theme—not claims about live bot activity.</p><p>Molly’s source also has a seasonal alternate personality: a self-possessed, sharp-tongued story that begins with an unmarked parcel, a pair of shoes, and a whisper. The exact profile varies with the season.</p><div className="quote-card">“Keeping the community organized, the team informed, and the details in order.”<span>— paraphrased from Molly’s default profile</span></div></div></section>
    <section className="values-grid"><article><b>01</b><h3>Helpful first</h3><p>Real tools for economy, utility, moderation, and community.</p></article><article><b>02</b><h3>Virtual only</h3><p>Coins and shop items are playful bot features—never real money.</p></article><article><b>03</b><h3>Room to grow</h3><p>This website is a companion. Molly’s bot and its data stay on their own.</p></article></section><div className="egg-wrap"><EasterEgg /></div>
  </div>;
}

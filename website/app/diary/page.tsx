import type { Metadata } from "next";
import { PageIntro } from "@/components/site-shell";
export const metadata: Metadata = { title: "GRWM & Diary" };
const posts = [
  { date: "MOODBOARD · SAMPLE", title: "A strawberry-milk morning", text: "Soft pinks, a favorite gloss, and a playlist for getting your server ready for the day.", color: "diary-pink", icon: "🍓" },
  { date: "GRWM · SAMPLE", title: "Ready, set, refresh", text: "A pretend little routine: hydrate, pick a bow, and check in with your community.", color: "diary-lavender", icon: "🫧" },
  { date: "LITTLE NOTE · SAMPLE", title: "Make room for cozy", text: "A reminder that the best online spaces feel welcoming, safe, and a little bit yours.", color: "diary-cream", icon: "🧸" },
];
export default function DiaryPage() {
  return <div className="page-container"><PageIntro eyebrow="a local moodboard, just for fun" title="GRWM & diary." copy="Little beauty notes and preppy inspiration, written as versioned sample content—not live posts or activity from Molly." /><div className="sample-banner">✦ SAMPLE CONTENT ✦ These are static examples saved with the website. No live feed is connected.</div><div className="diary-grid">{posts.map((post) => <article className={`diary-card ${post.color}`} key={post.title}><div className="diary-visual"><span>{post.icon}</span><b>♡</b></div><div className="diary-copy"><span className="eyebrow">{post.date}</span><h2>{post.title}</h2><p>{post.text}</p><span className="diary-read">A little note from Molly’s moodboard ✦</span></div></article>)}</div></div>;
}

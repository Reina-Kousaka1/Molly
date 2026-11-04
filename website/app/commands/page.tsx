import type { Metadata } from "next";
import { PageIntro } from "@/components/site-shell";
import { CommandBrowser } from "@/components/command-browser";
import { commands } from "@/lib/commands";
export const metadata: Metadata = { title: "Commands" };
export default function CommandsPage() {
  return <div className="page-container"><PageIntro eyebrow="the actual command closet" title="Commands, cutie." copy="Search Molly’s real command list. Prefix and slash availability, parameters, and permissions vary by command." /><CommandBrowser commands={commands} /></div>;
}

import type { Metadata } from "next";
import { PageIntro } from "@/components/site-shell";
export const metadata: Metadata = { title: "Imprint" };
export default function ImprintPage() {
  return <div className="page-container legal-page"><PageIntro eyebrow="legal · information required" title="Imprint." copy="Provider information has not been supplied or independently verified." /><div className="legal-callout">Publication is blocked until the responsible provider determines and supplies the required legal information for the applicable jurisdiction.</div><section><h2>Service provider</h2><p>[Verified full legal name]<br/>[Verified postal address]<br/>[Verified email or other required contact method]</p></section><section><h2>Responsible for content</h2><p>[Complete only if applicable, with verified required details.]</p></section><section><h2>Dispute resolution and registrations</h2><p>[Add only verified information required for this service and jurisdiction.]</p></section></div>;
}

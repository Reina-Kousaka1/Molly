import type { Metadata, Viewport } from "next";
import { SiteFooter, SiteHeader } from "@/components/site-shell";
import "./styles.css";

export const metadata: Metadata = {
  title: { default: "Molly — your preppy Discord bestie", template: "%s · Molly" },
  description: "Meet Molly, browse her real Discord commands, and peek at her virtual beauty shop.",
  applicationName: "Molly",
};

export const viewport: Viewport = { themeColor: "#fff9fc", width: "device-width", initialScale: 1 };
// A request-scoped CSP nonce is generated in proxy.ts; avoid serving HTML
// prerendered without the matching nonce on its inline Next.js runtime scripts.
export const dynamic = "force-dynamic";

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><a className="skip-link" href="#main">Skip to content</a><div className="site-wrap"><SiteHeader /><main id="main">{children}</main><SiteFooter /></div></body></html>;
}

"use client";

import { useMemo, useState } from "react";
import type { Command } from "@/lib/commands";

export function CommandBrowser({ commands }: { commands: Command[] }) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("All");
  const categories = ["All", ...Array.from(new Set(commands.map((command) => command.category)))];
  const filtered = useMemo(() => commands.filter((command) => {
    const matchesQuery = `${command.name} ${command.description} ${command.usage}`.toLowerCase().includes(query.toLowerCase());
    return matchesQuery && (category === "All" || command.category === category);
  }), [commands, query, category]);
  return <>
    <div className="command-controls"><label className="search-box"><span aria-hidden="true">⌕</span><span className="sr-only">Search commands</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search commands…" /></label>
      <div className="filter-row" aria-label="Filter commands by category">{categories.map((item) => <button key={item} className={`filter-chip ${category === item ? "selected" : ""}`} onClick={() => setCategory(item)} aria-pressed={category === item}>{item}</button>)}</div>
    </div>
    <p className="result-count" aria-live="polite">{filtered.length} command{filtered.length === 1 ? "" : "s"} found · verified against Molly&apos;s command registry</p>
    <div className="command-grid">{filtered.map((command) => <article className="command-card" key={command.name}><div className="command-card-top"><code>{command.name}</code><span className="tag">{command.category}</span></div><p>{command.description}</p><div className="usage"><span>TRY IT</span><code>{command.usage}</code></div></article>)}</div>
    {filtered.length === 0 && <div className="empty-state">No commands match that search. Try a different word, cutie.</div>}
    <p className="fine-print">Some entries use slash-command subcommands. Prefix support is only shown where Molly registers it. Availability can depend on your server’s settings and permissions.</p>
  </>;
}

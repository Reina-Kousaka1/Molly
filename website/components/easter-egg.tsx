"use client";

import { useState } from "react";

export function EasterEgg() {
  const [open, setOpen] = useState(false);
  return <div className="easter-egg"><button type="button" className="button button-soft" aria-expanded={open} onClick={() => setOpen((value) => !value)}>Tap the tiny bow <span aria-hidden="true">🎀</span></button>{open && <p role="status">Molly keeps a few mysteries to herself. 🗝️</p>}</div>;
}

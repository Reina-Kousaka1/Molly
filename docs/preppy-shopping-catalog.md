# Molly V1.2 virtual retail catalog

This is a reviewed, deliberately curated catalog snapshot. It is not a full retailer
catalog or a live availability feed. Purchases are fictional Molly Coin transactions;
Molly is not affiliated with Sephora, lululemon, or Pandora. No product images or
retailer descriptions are copied into the bot.

## Snapshot rules

- Catalog schema version: `1` (`src/economy/retail_catalog.lua`). Product IDs are
  stable; inventory owns variant IDs.
- Price snapshot checked: `2026-11-05`.
- FX: ECB reference rate `1 EUR = 1.1221 USD`, stored as `11221 / 10000`.
- Formula, using integer cents: round half up `((EU cents + USD cents / USD-per-EUR) * 25 / 19)`.
  This is equivalent to the requested average-EUR-price formula and `1 coin = €0.0038`.
- Prices are reference/list prices, not checkout offers. For the Pandora bracelet the
  official US page displayed a temporary sale alongside the regular $200 list price;
  the snapshot uses the regular price. The code performs no price or FX network calls.
  Updating a price requires a reviewed source-data change.
- A completed retail purchase stores the cents, FX rate/date/source, rounding policy,
  calculated Coin price, and snapshot date on its ledger journal row and receipt.
  A retry uses the existing receipt; it cannot recalculate or double-charge.

## Included catalog coverage

| Department | Product | Variants | EUR / USD reference | Coin price |
| --- | --- | ---: | ---: | ---: |
| Sephora | Drunk Elephant B-Hydra Intensive Hydration Serum, 50 ml | 1 | €52 / $56 | 13,409 |
| Sephora | Rare Beauty Soft Pinch Liquid Blush, 7.5 ml | 6 selected shades | €29 / $25 | 6,747 |
| lululemon | Define Jacket Nulu, Pink Pearl/Gold/Gold | US 0–14 (even sizes) | €128 / $128 | 31,851 |
| Pandora | Entwined Heart & Butterfly Pendant Necklace, 394477C01 | 1 | €75 / $98 | 21,361 |
| Pandora | Elevated Heart Ring, 198421C01 | EU 48, 50, 52, 54, 56, 58, 60 | €69 / $98 | 20,571 |
| Pandora | Rainbow Tennis Necklace, 394648C01 | 1 | €139 / $190 | 40,570 |
| Pandora | Moments Heart Closure Snake Chain Bracelet, 582257C00 | 3 verified lengths | €119 / $200 list | 39,111 |

Totals: 7 products and 27 selectable variants. The six blush shades are Hope, Joy,
Happy, Grateful, Grace, and Love. The three verified bracelet lengths included are 16, 21,
and 23 cm. The Rainbow Tennis and heart pendant necklaces are represented
as one-size variants. The silver Elevated Heart Ring shown in the user-provided screenshot
matches Pandora's `198421C01` reference; its seven virtual variants use EU ring sizes 48–60
in two-size steps. Retail availability can change; `available` means included in
this virtual catalog, not current stock at a retailer.

## Sources

- [Sephora France: B-Hydra 50 ml, €52](https://www.sephora.fr/p/b-hydra-intensive-hydration---serum-P10013690.html)
- [Sephora US: B-Hydra 50 ml, $56, item 1785856](https://www.sephora.com/product/b-hydra-intensive-hydration-gel-P406712?country_switch=us)
- [Sephora France: Soft Pinch, €29 and shades](https://www.sephora.fr/p/soft-pinch---liquid-blush-651745.html)
- [Sephora US: Soft Pinch, $25](https://www.sephora.com/buy/blush-under-30)
- [lululemon Germany: Define Jacket Nulu, Pink Pearl](https://www.lululemon.de/de-de/p/define-jacke-nulu/159403005.html)
- [lululemon US: Define Jacket Nulu, Pink Pearl, $128 and sizes 0–14](https://shop.lululemon.com/p/define-jacket-nulu/hnsjuvo8dn?color=76033)
- [Pandora Germany: Entwined Heart & Butterfly, €75, 394477C01](https://de.pandora.net/de/ketten/ketten-mit-anhanger/verschlungenes-herz-und-schmetterling-anhanger-halskette-/394477C01.html)
- [Pandora US: Entwined Heart & Butterfly, $98](https://us.pandora.net/en/necklaces/pendant-necklaces/entwined-heart-butterfly-pendant-necklace/394477C01.html)
- [Pandora Germany: Elevated Heart Ring, sterling silver, €69, 198421C01](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01.html)
- [Pandora US: Elevated Heart Ring, sterling silver, $98, 198421C01](https://us.pandora.net/en/rings/elevated-heart-ring/198421C01.html)
- [Pandora Germany: product page with size 48](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01-48.html), [size 50](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01-50.html), [size 52](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01-52.html), [size 56](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01-56.html), and [size 60](https://de.pandora.net/de/ringe/statement-ringe/erhabenes-herz-ring/198421C01-60.html); size 58 is listed on [Pandora Spain](https://es.pandora.net/es/anillos/anillos/anillos-de-plata/anillo-corazon-en-relieve/198421C01-58.html). Pandora's [German size guide](https://de.pandora.net/on/demandware.store/Sites-de-DE-Site/de_DE/Product-SizeGuide?pid=190980) documents the EU sizes.
- [Pandora Austria: Rainbow Tennis Necklace, €139, 394648C01](https://at.pandora.net/de/ketten/gliederketten/regenbogenfarbene-tennishalskette/394648C01.html)
- [Pandora US: Rainbow Tennis Necklace, $190](https://us.pandora.net/en/necklaces/chain-necklaces/rainbow-tennis-necklace/394648C01.html)
- [Pandora Germany: rose-plated Heart Closure Snake Chain Bracelet, €119, 582257C00](https://de.pandora.net/de/armbander/charm-armbander/pandora-moments-herzverschluss-schlangen-gliederarmband/582257C00.html)
- [Pandora US: bracelet, $200 regular list price with an observed temporary sale](https://us.pandora.net/en/charms-bracelets/bracelets/charm-bracelets/pandora-moments-heart-closure-snake-chain-bracelet/582257C00.html)
- [ECB euro reference rates](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html)

## Explicit exclusions and future integration points

- The requested silver heart ring is included as Pandora Elevated Heart Ring `198421C01`,
  matched to the supplied screenshot and official Pandora product references. The current
  curated price snapshot uses €69 EU / $98 US and the documented ECB rate. The listed
  size variants are EU 48, 50, 52, 54, 56, 58, and 60; current retailer stock is not modeled.
- Sephora and lululemon coverage is a small verified sample, not comprehensive.
  Pandora contains the four selected pieces above.
- No official product feed/API was identified or integrated. There is no scraper,
  automatic stock refresh, automatic price refresh, or FX refresh.
- `/shop browse`, `/shop search`, and `/shop item` operate on the curated subset;
  `/shop buy item:<variant-id>` purchases a listed variant. `/shop cart`, `/shop
  wishlist`, and `/shop favorites` have guild-scoped bounded persistence. The cart is
  a saved list only; checkout is deliberately unavailable until a fully atomic
  multi-item transaction is implemented. The legacy catalog and `/transactions`
  history remain available. Named saved outfits and product-import tooling are not
  yet implemented.
- Fashion equipment supports outfit, necklace, and bracelet slots. Ring remains
  available as a slot type for a future verified item. Other product categories are
  virtual collectibles, not equipable objects.
- Daily claims award 1,500–3,500 base coins, weekly claims 6,000–12,000, and work
  claims 400–1,800. Work cooldown is six hours. Daily streak milestones add 250 at
  streak 5, 500 at 10, and 750 at 25; weekly streak milestones add 1,500 at 4 and
  3,000 at 12. Daily streak continues through a 48-hour claim gap; weekly streak
  continues through a 14-day gap. Missed windows reset to streak 1. Bonuses are
  included in the committed reward and receipt. No existing balance is modified.
- `tests/economy_simulation.lua` simulates 30 days at midpoint rewards. It models one,
  three, or four work claims a day plus one daily claim and weekly claims on days 1,
  8, 15, 22, and 29. The executed CI model reported no-spend totals of 169,250 (casual),
  235,250 (regular), and 268,250 (very active) coins. First affordability in the same
  run was: B-Hydra 2/1/1 days, blush 1/1/1, heart necklace 4/3/2, bracelet 8/6/5,
  and Define Jacket 7/4/4 for casual/regular/very-active profiles. This is a deterministic
  model, not observed player data; frequent work allows highly active profiles to reach
  premium items sooner than the desired 8–20-day clothing target.

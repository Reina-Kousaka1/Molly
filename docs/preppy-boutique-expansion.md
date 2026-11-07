# Molly Preppy Boutique expansion

Research reviewed on **2026-11-07**. The sources informed product *types and visual mood only*; Molly's five added products below are fictional, independently named, and have original descriptions. No retailer inventory, prices, product descriptions, imagery, logos, SKUs, or catalog rows were imported from these sources.

## Trend inspiration

- Pinterest's 2026 Beauty Trend Report highlights frosted/metallic finishes, pastel-blue shadow, berry and dusty-rose blush, body-care routines, and soft gourmand fragrance searches. These are search-interest signals in Pinterest's report, not a claim that Molly's items are current bestsellers: [Pinterest Newsroom, 2026 Beauty Trend Report](https://newsroom.pinterest.com/news/beauty-trend-report-2026/).
- Sephora currently presents a lip-products edit spanning lip treatments, balms, glosses, and oils. This is used only as a category reference, not as a full catalog or endorsement: [Sephora, Trending Lip Balms, Oils & Glosses](https://www.sephora.com/beauty/best-lip-products?icid2=bestselling_lip_products_buying_guide_action).
- Vogue's 2026 lip coverage discusses hydrating gloss oils, sheer lips, and staining oils; its body-care coverage discusses skin-care routines and fragrance layering: [Vogue, 2026 Lip Trends](https://www.vogue.com/article/lip-trends-2026), [Vogue, 2026 Body-Care Trends](https://www.vogue.com/article/body-care-trends-2026).

## Added fictional Molly products

All five records are additive and use new stable IDs. Prices use Molly's existing fixed virtual-value rule (`1 Molly Coin = €0.0038`, rounded half-up), while remaining fictional in-game values rather than retailer prices.

| Item ID | Molly product | Category / collection | Price |
| --- | --- | --- | ---: |
| `molly_berryglass_lip_oil` | Berryglass Lip Oil | Makeup / Molly Glossy Era | 5,789 coins |
| `molly_cloudberry_sleep_mask` | Cloudberry Sleep Mask | Skincare / Pink Cloud Skincare | 6,842 coins |
| `molly_petal_veil_blush` | Petal Veil Cream Blush | Makeup / Molly Glossy Era | 7,368 coins |
| `molly_pink_cloud_mist` | Pink Cloud Hydration Mist | Skincare / Pink Cloud Skincare | 6,316 coins |
| `molly_satin_bow_claw` | Satin Bow Claw Clip | Accessories / Preppy Essentials | 4,737 coins |

The five products are added by `src/economy/catalog_extensions.lua` as an additive overlay; existing catalog IDs, stored ownership, ledger receipts, and purchase paths remain unchanged. The bow clip uses the existing `head` equipment slot. The other four are collectibles. No VIP discount or cart checkout was added.

## Product preview assets

Three original, unbranded illustrations are stored under `assets/shop/` and delivered as static images from the Molly repository's `raw.githubusercontent.com` asset path. Discord item details choose an image by item department/category (beauty, fashion, or accessories/jewelry). These are department-style illustrations, not photorealistic representations of each exact item. Each detail falls back to a small bow marker if no safe mapping exists. No user-supplied URL is fetched or used; there is no image download at runtime. The image URL builder only returns the three exact asset paths, and an allowlist check guards the mapping.

The image assets were generated specifically for Molly on 2026-11-07. They contain no readable labels, retailer marks, product logos, copied packaging, or retailer photography. They are original category previews, not exact depictions of branded products.

## Shop detail flow and limits

`/shop item product:<id>` now displays an item-specific embed title, the catalog's existing description, category, collection, virtual rarity/tier, Molly Coin price or paged variant prices, availability, purchase syntax, and an allowlisted image thumbnail. Both standard virtual items and curated retail-reference product pages use the same existing command and embed response pipeline. Purchase logic remains in the existing Shop/Ledger path; this change does not create a second purchase implementation.

The preview does not add buttons, a checkout flow, stock claims, or external product image retrieval. Existing browse/search pagination remains the navigation mechanism. Retail-reference images are original Molly illustrations and do not claim retailer availability.

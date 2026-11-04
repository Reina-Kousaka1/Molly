# Molly Website

This is a separate Next.js companion website for the Lua/Luvit Molly bot. It does not replace Molly and does not connect to SeaWorld DB or PreppyDB.

## Local development

```sh
npm ci
npm run dev
```

The public pages are `/`, `/meet-molly`, `/commands`, `/shop`, `/diary`, `/support`, and `/legal/*`. The command snapshot is checked against the main-branch `src/commands/` tree. The current main branch has no item catalog or shop command, so `/shop` is a clearly labeled unavailable preview and displays no invented prices. Update the website snapshot and its tests when Molly’s source changes.

## Dashboard boundary

The current Molly repository has no authenticated website API, no supported-guild registry endpoint, and no public runtime health endpoint. The dashboard therefore labels server selection, bot status, economy history/configuration, moderation controls, shop configuration, and audit logs unavailable. Do not connect the browser to SeaWorld or PreppyDB and do not add public bot-control routes as a substitute.

Optional Discord identity login uses the OAuth2 authorization-code flow with signed state and the `identify` scope. The authorization code is exchanged server-side; the access token is used only to fetch the user profile and is not persisted. A signed `HttpOnly`, `SameSite=Lax` cookie stores minimal identity claims for eight hours. Logout requires same-origin plus a session CSRF token. OAuth is disabled unless the server environment has all of:

- `DISCORD_CLIENT_ID`
- `DISCORD_CLIENT_SECRET`
- `DISCORD_REDIRECT_URI` (exact registered callback, ending in `/api/auth/callback`)
- `SESSION_SECRET` (at least 32 characters of cryptographically random material)

The account’s server list is intentionally not requested: Molly cannot verify which servers she currently supports. No credential values belong in source control or `NEXT_PUBLIC_*` variables.

## Vercel setup (not yet connected)

Import this repository with the project root set to `website/`, framework preset Next.js, and Node.js 20.9 or newer. Add the four server-only OAuth/session variables only after configuring the Discord application redirect URI and completing the security review. Set `NEXT_PUBLIC_DISCORD_INVITE` only to a verified `https://discord.com/oauth2/authorize` invite URL. Preview and Production should use separate Discord OAuth applications/secrets where possible. The legal pages currently contain explicit publication-blocking placeholders and must be completed with verified operator details before publication.

## Verification

```sh
npm run lint
npm run typecheck
npm test
npm run build
npx playwright install chromium
npm run test:e2e
```

Browser tests cover 360, 390, 768, and 1440 CSS-pixel viewports, command search, dashboard access boundaries, security headers, and axe WCAG 2.1 AA checks on the main pages.

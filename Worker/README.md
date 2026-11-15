# social-stats

The Cloudflare Worker behind CreatorOS Socials (YouTube only for now). It holds the Google OAuth tokens (encrypted), reads the channel's numbers every 15 minutes, stores them in D1 and serves them to the Mac app, CLI, iPhone companion and widget.

It only ever serves figures YouTube returned. It never adds, subtracts or projects them.

The contract (routes, JSON shapes, auth, read schedule, retention) is in [`../docs/SOCIALS-API.md`](../docs/SOCIALS-API.md). The client is `Sources/SocialsCore/SocialsCore.swift`.

## One-time deploy

Run these from this folder. Nothing here has been deployed yet, and `database_id` in `wrangler.jsonc` is a placeholder until step 2.

1. `npm install`. (npm 12 blocks install scripts, so `package.json` lists `workerd` and `esbuild` under `allowScripts`.)
2. `npx wrangler login`, then `npx wrangler d1 create social-stats`. Paste the printed `database_id` over `REPLACE_AT_DEPLOY` in `wrangler.jsonc`.
3. `npx wrangler d1 migrations apply social-stats --remote`
4. In Google Cloud, create a Web OAuth client with YouTube Data API v3 and YouTube Analytics API enabled. Add the redirect URI `https://social-stats.<your-subdomain>.workers.dev/v1/youtube/callback`.
5. Set the four secrets, one `npx wrangler secret put <NAME>` each:
   - `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, from step 4.
   - `TOKEN_KEY`, the AES-GCM key for stored tokens: `openssl rand -base64 32`
   - `ENROL_CODE`, the one-time code for the first device: `openssl rand -base64 24 | tr '+/' '-_' | tr -d '='`
6. `npx wrangler deploy`
7. In the app, enrol the first device with `ENROL_CODE` (it works once). Further devices pair with a code from `POST /v1/devices/pair`.

`/privacy` is the public privacy policy to give Google for the OAuth consent screen.

## Routes

`POST /v1/devices/enrol`, `POST /v1/devices/pair`, `GET /v1/devices`, `POST /v1/devices/{id}/revoke`, `GET /v1/status`, `GET /v1/summary`, `GET /v1/history`, `POST /v1/youtube/connect`, `GET /v1/youtube/callback`, `POST /v1/youtube/disconnect`, `POST /v1/refresh`, `POST /v1/delete-all`, `GET /privacy`. Everything except enrol, the callback and `/privacy` needs `Authorization: Bearer <device token>`. Details in the contract.

## Development

- `npm test` runs the vitest suite in the Workers runtime with D1 migrations applied and Google mocked.
- `npx tsc --noEmit` type-checks. After changing `wrangler.jsonc`, run `npx wrangler types`.

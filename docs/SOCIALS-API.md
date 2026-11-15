# Socials Worker API, v1

The contract between the `social-stats` Cloudflare Worker (`Worker/`), `SocialsCore` (Mac app, CLI, iPhone companion and widget). Change both sides together. Times are ISO 8601 UTC strings; dates are `YYYY-MM-DD` as YouTube returns them.

Only figures the platform API returns are served. Nothing is summed, subtracted or projected (YouTube developer policy III.E.4, derived metrics). The one exception is selection: the Worker picks which returned rows to show, never computes new values from them.

## Auth

Every route except the OAuth callback and `/privacy` needs `Authorization: Bearer <device token>`. The Worker stores only SHA-256 of each token. A revoked or unknown token gets `401 {"error":"unauthorized"}`; the device must then wipe its cache and credential.

Errors are `{"error": "<code>", "message": "<human text>"}` with a 4xx/5xx status.

## Routes

| Method, path | Body / query | Response |
|---|---|---|
| `POST /v1/devices/enrol` | `{"code","name","kind":"mac"\|"iphone"\|"cli"}` | `{"deviceId","token"}`. `code` is the one-time deploy code (`ENROL_CODE` secret, accepted once) or a pairing code. |
| `POST /v1/devices/pair` | – | `{"code","expiresAt"}`. Single use, 10 minutes. |
| `GET /v1/devices` | – | `{"devices":[{"id","name","kind","createdAt","lastSeenAt","current":bool}]}` |
| `POST /v1/devices/{id}/revoke` | – | `{"ok":true}` |
| `GET /v1/status` | – | `Status` below |
| `GET /v1/summary` | – | `Summary` below |
| `GET /v1/history` | `?platform=youtube&days=7\|28\|90` | `History` below |
| `POST /v1/youtube/connect` | – | `{"authUrl"}`. Opens Google consent; `state` is single-use, tied to the calling device, 10 minutes, PKCE S256. |
| `GET /v1/youtube/callback` | Google's `code`, `state` | Small dark HTML page: connected / failed. |
| `POST /v1/youtube/disconnect` | – | Revokes at Google, deletes tokens and all YouTube data at once. `{"ok":true}` |
| `POST /v1/refresh` | – | Reads every connected platform now (at most once per 60 s, else `429`). Returns `Summary`. |
| `POST /v1/delete-all` | – | Revokes and deletes every platform's tokens and data. Devices stay enrolled. `{"ok":true}` |
| `GET /privacy` | – | Public privacy policy (HTML). |

## Shapes

```jsonc
// Status
{
  "serverTime": "2026-11-15T16:00:00Z",
  "platforms": [{
    "platform": "youtube",
    "state": "connected" | "disconnected" | "needsReconnect",
    "account": "Junior Nkana Bassi" | null,        // channel title
    "lastGoodReadAt": "…" | null,
    "lastAttemptAt": "…" | null,
    "lastError": "http 403" | null,                 // platform + status only, never tokens
    "readIntervalMinutes": 15,
    "gaps": [{"from": "…", "to": "…"}]              // failed reads in the last 7 days
  }],
  "deletions": [{"platform": "youtube", "at": "…"}] // devices clear that platform's cache if their copy is older
}

// Summary
{
  "serverTime": "…",
  "youtube": null | {
    "state": "connected" | "needsReconnect",
    "connectionId": "uuid",           // changes on every (re)connect; devices drop data from another connection
    "channelTitle": "…",
    "subscriberCount": 4810,          // as YouTube returns it (rounded to 3 significant figures)
    "subscriberCountHidden": false,
    "countsReadAt": "…",              // when the Worker read subscriberCount and newestVideo
    "window": null | {                // YouTube Analytics totals for the latest 28 days YouTube reports
      "startDate": "2026-10-16", "endDate": "2026-11-12",
      "partial": false,               // true when YouTube returned fewer than 28 daily rows in that range
      "views": 1234, "estimatedMinutesWatched": 5678,
      "subscribersGained": 90, "subscribersLost": 4,
      "readAt": "…"
    },
    "newestVideo": null | {"id","title","publishedAt","viewCount","url"}
  }
}

// History
{
  "platform": "youtube",
  "connectionId": "uuid" | null,     // the connection these rows belong to; null when nothing is connected
  "readAt": "…" | null,
  "rows": [{"date": "2026-11-01", "views": 1, "estimatedMinutesWatched": 2, "subscribersGained": 3, "subscribersLost": 0}],
  "lastReportedDate": "2026-11-12" | null   // days after this have no YouTube data yet ("not yet reported")
}
```

## Read schedule

Cron every 15 minutes: renew the Google access token (this is also the 30-day "still authorised" check), `channels.list?mine=true&part=snippet,statistics,contentDetails`, `playlistItems.list` (uploads, 1 item), `videos.list` (statistics). Once a day (first run after 06:00 UTC) or when no window exists: YouTube Analytics `reports.query` with `dimensions=day` over the last 100 days, then a total query for the 28 days ending on the last returned day. About 290 Data API units a day.

## Retention

- Disconnect, delete-all: tokens and data deleted at once.
- `invalid_grant` on renewal: state `needsReconnect`, last numbers kept greyed; all YouTube data purged 30 days after the first failure if not reconnected.
- Titles and other non-statistics are rewritten every read, so none is older than 30 days while connected.
- Readings older than 100 days are deleted.

## Device rules (SocialsCore)

- Cache file per data root, separate from `library.json`, with each figure's read time.
- No successful contact for 7 days: show "Offline, data expired", hide figures. 30 days: delete the cache file.
- `401`: wipe the cache and the credential.
- History is kept only when its `connectionId` matches the summary's; a changed `connectionId` drops all cached history.
- The Worker builds each summary and history from one connection: it reads the account's `connectionId` once and constrains every lookup to it.
- A `deletions` entry newer than the cached copy: drop that platform from the cache.

import { DAY, at, seal, unseal } from "./util";

export const TOKEN_URL = "https://oauth2.googleapis.com/token";
export const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const DATA_API = "https://www.googleapis.com/youtube/v3";
const ANALYTICS_API = "https://youtubeanalytics.googleapis.com/v2/reports";
const METRICS = "views,estimatedMinutesWatched,subscribersGained,subscribersLost";

export interface Account {
  refresh_token_enc: string;
  access_token_enc: string | null;
  access_expires_at: string | null;
  state: "connected" | "needsReconnect";
  first_failure_at: string | null;
}

// Failure messages are stored and served, so they carry a status or a fixed word, never a body or header.
class ReadError extends Error {}
class Reconnect extends Error {}

type Json = any; // Google responses are read field by field below.

async function api(url: string, token: string): Promise<Json> {
  const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new ReadError(`http ${r.status}`);
  return r.json();
}

const int = (v: unknown) => {
  const n = parseInt(String(v), 10);
  return Number.isNaN(n) ? null : n;
};

const addDays = (ymd: string, n: number) => new Date(Date.parse(ymd) + n * DAY).toISOString().slice(0, 10);

// shortcut: no per-account Durable Object lock; Google refresh tokens do not rotate. Add one before TikTok, whose tokens rotate.
async function accessToken(env: Env, acc: Account) {
  if (acc.access_token_enc && acc.access_expires_at && acc.access_expires_at > at(5 * 60_000)) {
    return unseal(env, acc.access_token_enc);
  }
  const r = await fetch(TOKEN_URL, {
    method: "POST",
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      refresh_token: await unseal(env, acc.refresh_token_enc),
      grant_type: "refresh_token",
    }),
  });
  if (!r.ok) {
    const e: Json = await r.json().catch(() => ({}));
    throw e?.error === "invalid_grant" ? new Reconnect() : new ReadError(`http ${r.status}`);
  }
  const j: Json = await r.json();
  await env.DB.prepare("UPDATE accounts SET access_token_enc=?, access_expires_at=? WHERE platform='youtube'")
    .bind(await seal(env, j.access_token), at(j.expires_in * 1000))
    .run();
  return j.access_token as string;
}

async function fetchCounts(env: Env, token: string) {
  const ch = (await api(`${DATA_API}/channels?part=snippet,statistics,contentDetails&mine=true`, token)).items?.[0];
  if (!ch) throw new ReadError("no channel");
  const hidden = ch.statistics?.hiddenSubscriberCount === true;
  await env.DB.prepare("UPDATE accounts SET account_title=? WHERE platform='youtube'").bind(ch.snippet?.title ?? null).run();

  let newestVideo = null;
  const uploads = ch.contentDetails?.relatedPlaylists?.uploads;
  const id = uploads && (await api(`${DATA_API}/playlistItems?part=contentDetails&maxResults=1&playlistId=${uploads}`, token)).items?.[0]?.contentDetails?.videoId;
  if (id) {
    const v = (await api(`${DATA_API}/videos?part=snippet,statistics&id=${id}`, token)).items?.[0];
    if (v) newestVideo = { id, title: v.snippet.title, publishedAt: v.snippet.publishedAt, viewCount: int(v.statistics?.viewCount), url: `https://www.youtube.com/watch?v=${id}` };
  }
  return { channelTitle: ch.snippet?.title ?? "", subscriberCount: hidden ? null : int(ch.statistics?.subscriberCount), hidden, newestVideo };
}

// Only figures YouTube returned are stored: the window comes from its own total query, never from summing daily rows.
async function fetchAnalytics(token: string) {
  const query = (p: Record<string, string>) => api(`${ANALYTICS_API}?${new URLSearchParams({ ids: "channel==MINE", metrics: METRICS, ...p })}`, token);
  const named = (res: Json, row: unknown[]) => Object.fromEntries(res.columnHeaders.map((c: Json, i: number) => [c.name, row[i]]));

  const today = at().slice(0, 10);
  const daily = await query({ startDate: addDays(today, -100), endDate: today, dimensions: "day", sort: "day" });
  const rows = (daily.rows ?? []).map((r: unknown[]) => {
    const o = named(daily, r);
    return { date: o.day, views: o.views, estimatedMinutesWatched: o.estimatedMinutesWatched, subscribersGained: o.subscribersGained, subscribersLost: o.subscribersLost };
  });
  if (!rows.length) return { rows, window: null };

  const endDate: string = rows[rows.length - 1].date;
  const startDate = addDays(endDate, -27);
  const total = await query({ startDate, endDate });
  const t = total.rows?.[0] && named(total, total.rows[0]);
  const window = t && {
    startDate, endDate,
    partial: rows.filter((r: { date: string }) => r.date >= startDate).length < 28,
    views: t.views, estimatedMinutesWatched: t.estimatedMinutesWatched, subscribersGained: t.subscribersGained, subscribersLost: t.subscribersLost,
  };
  return { rows, window: window ?? null };
}

async function analyticsDue(env: Env) {
  const last = await env.DB.prepare("SELECT read_at FROM readings WHERE platform='youtube' AND kind='analytics' AND ok=1 ORDER BY read_at DESC LIMIT 1").first<{ read_at: string }>();
  const sixToday = at().slice(0, 10) + "T06:00:00.000Z";
  return !last || (at() >= sixToday && last.read_at < sixToday);
}

// One reading row per step, ok or not. The stored error is a status or a fixed word only.
async function step(env: Env, kind: "counts" | "analytics", fn: () => Promise<unknown>) {
  const now = at();
  let ok = 1, payload: unknown, error: string | null = null;
  try {
    payload = await fn();
  } catch (e) {
    ok = 0;
    error = e instanceof Reconnect ? "invalid_grant" : e instanceof ReadError ? e.message : "read failed";
    payload = { error };
    if (e instanceof Reconnect) {
      await env.DB.prepare("UPDATE accounts SET state='needsReconnect', first_failure_at=COALESCE(first_failure_at, ?) WHERE platform='youtube'").bind(now).run();
    }
  }
  await env.DB.batch([
    env.DB.prepare("INSERT INTO readings (platform, kind, read_at, ok, payload) VALUES ('youtube', ?, ?, ?, ?)").bind(kind, now, ok, JSON.stringify(payload)),
    ok
      ? env.DB.prepare("UPDATE accounts SET last_good_read_at=?, last_error=NULL WHERE platform='youtube'").bind(now)
      : env.DB.prepare("UPDATE accounts SET last_error=? WHERE platform='youtube'").bind(error),
  ]);
  return !!ok;
}

// Cron and /v1/refresh. A needsReconnect account is left alone until the user reconnects.
export async function readYouTube(env: Env) {
  const acc = await env.DB.prepare("SELECT * FROM accounts WHERE platform='youtube' AND state='connected'").first<Account>();
  if (!acc) return;
  await env.DB.prepare("UPDATE accounts SET last_attempt_at=? WHERE platform='youtube'").bind(at()).run();
  let token = "";
  const counted = await step(env, "counts", async () => {
    token = await accessToken(env, acc);
    return fetchCounts(env, token);
  });
  if (counted && (await analyticsDue(env))) await step(env, "analytics", () => fetchAnalytics(token));
}

// Disconnect, delete-all and the 30-day purge: tokens and every stored row go at once, and a deletions row tells devices.
export async function wipe(env: Env, platform: string, revoke = true) {
  const acc = await env.DB.prepare("SELECT refresh_token_enc FROM accounts WHERE platform=?").bind(platform).first<{ refresh_token_enc: string }>();
  if (acc && revoke) {
    try {
      await fetch(REVOKE_URL, { method: "POST", body: new URLSearchParams({ token: await unseal(env, acc.refresh_token_enc) }) });
    } catch {} // best effort: the local delete below happens regardless
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM accounts WHERE platform=?").bind(platform),
    env.DB.prepare("DELETE FROM readings WHERE platform=?").bind(platform),
    env.DB.prepare("INSERT INTO deletions (platform, at) VALUES (?, ?)").bind(platform, at()),
  ]);
}

import { ApiError, DAY, ago, at, json, randomToken, readBody, safeEqual, seal, sha256, sha256Hex, b64url } from "./util";
import { page, privacy } from "./privacy";
import { TOKEN_URL, readYouTube, wipe } from "./youtube";

const PLATFORMS = ["youtube"];
const SCOPES = "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/yt-analytics.readonly";
const GAP_MS = 20 * 60_000; // failed reads closer than this belong to one gap (cron runs every 15 minutes)
const PAIR_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

interface Device { id: string }
interface Ctx { env: Env; request: Request; url: URL; exec: ExecutionContext; device: Device }
type Handler = (c: Ctx) => Promise<Response>;

const run = (env: Env, sql: string, ...args: unknown[]) => env.DB.prepare(sql).bind(...args).run();
const one = <T>(env: Env, sql: string, ...args: unknown[]) => env.DB.prepare(sql).bind(...args).first<T>();

async function authenticate(request: Request, env: Env): Promise<Device> {
  const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
  const device = token && (await one<Device>(env, "SELECT id FROM devices WHERE token_hash=? AND revoked_at IS NULL", await sha256Hex(token)));
  if (!device) throw new ApiError(401, "unauthorized", "Unknown or revoked device.");
  await run(env, "UPDATE devices SET last_seen_at=? WHERE id=?", at(), device.id);
  return device;
}

async function enrol({ env, request }: Ctx): Promise<Response> {
  const { code, name, kind } = await readBody(request);
  if (typeof code !== "string" || !code || typeof name !== "string" || !name.trim() || name.length > 100 || !["mac", "iphone", "cli"].includes(kind as string)) {
    throw new ApiError(400, "bad_request", "Expected code, name and kind (mac, iphone or cli).");
  }
  // The deploy code works once; otherwise the code must be an unused, unexpired pairing code.
  let allowed = false;
  if (await safeEqual(code, env.ENROL_CODE)) {
    allowed = (await run(env, "INSERT OR IGNORE INTO meta (key, value) VALUES ('deploy_code_used', '1')")).meta.changes === 1;
  }
  if (!allowed) {
    allowed = (await run(env, "UPDATE enrol_codes SET used_at=? WHERE code_hash=? AND used_at IS NULL AND expires_at>?", at(), await sha256Hex(code), at())).meta.changes === 1;
  }
  if (!allowed) throw new ApiError(403, "invalid_code", "That code is wrong, used or expired.");

  const deviceId = crypto.randomUUID();
  const token = randomToken();
  await run(env, "INSERT INTO devices (id, name, kind, token_hash, created_at) VALUES (?, ?, ?, ?, ?)", deviceId, name.trim(), kind, await sha256Hex(token), at());
  return json({ deviceId, token });
}

async function pair({ env }: Ctx): Promise<Response> {
  const code = Array.from(crypto.getRandomValues(new Uint8Array(10)), (b) => PAIR_CHARS[b % PAIR_CHARS.length]).join("");
  const expiresAt = at(10 * 60_000);
  await run(env, "INSERT INTO enrol_codes (code_hash, kind, expires_at) VALUES (?, 'pair', ?)", await sha256Hex(code), expiresAt);
  return json({ code, expiresAt });
}

async function devices({ env, device }: Ctx): Promise<Response> {
  const { results } = await env.DB.prepare("SELECT id, name, kind, created_at, last_seen_at FROM devices WHERE revoked_at IS NULL ORDER BY created_at").all<Record<string, string>>();
  return json({ devices: results.map((d) => ({ id: d.id, name: d.name, kind: d.kind, createdAt: d.created_at, lastSeenAt: d.last_seen_at, current: d.id === device.id })) });
}

async function revoke({ env, url }: Ctx): Promise<Response> {
  const id = url.pathname.split("/")[3];
  const r = await run(env, "UPDATE devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL", at(), id);
  if (!r.meta.changes) throw new ApiError(404, "not_found", "No such device.");
  return json({ ok: true });
}

interface Row { read_at: string; payload: string }
const latest = async (env: Env, kind: string) => {
  const r = await one<Row>(env, "SELECT read_at, payload FROM readings WHERE platform='youtube' AND kind=? AND ok=1 AND connection_id=(SELECT connection_id FROM accounts WHERE platform='youtube') ORDER BY read_at DESC LIMIT 1", kind);
  return r && { readAt: r.read_at, ...JSON.parse(r.payload) };
};

async function buildSummary(env: Env) {
  const acc = await one<{ state: string; account_title: string | null }>(env, "SELECT state, account_title FROM accounts WHERE platform='youtube'");
  let youtube = null;
  if (acc) {
    const [counts, analytics] = await Promise.all([latest(env, "counts"), latest(env, "analytics")]);
    youtube = {
      state: acc.state,
      channelTitle: acc.account_title ?? "",
      subscriberCount: counts?.subscriberCount ?? null,
      subscriberCountHidden: counts?.hidden ?? false,
      countsReadAt: counts?.readAt ?? null,
      window: analytics?.window ? { ...analytics.window, readAt: analytics.readAt } : null,
      newestVideo: counts?.newestVideo ?? null,
    };
  }
  return { serverTime: at(), youtube };
}

async function status({ env }: Ctx): Promise<Response> {
  const acc = await one<Record<string, string | null>>(env, "SELECT * FROM accounts WHERE platform='youtube'");
  const { results: failed } = await env.DB.prepare("SELECT read_at FROM readings WHERE platform='youtube' AND ok=0 AND read_at>? ORDER BY read_at").bind(ago(7 * DAY)).all<{ read_at: string }>();
  const gaps: { from: string; to: string }[] = [];
  for (const { read_at } of failed) {
    const g = gaps.at(-1);
    if (g && Date.parse(read_at) - Date.parse(g.to) <= GAP_MS) g.to = read_at;
    else gaps.push({ from: read_at, to: read_at });
  }
  const { results: deletions } = await env.DB.prepare("SELECT platform, at FROM deletions ORDER BY at").all();
  return json({
    serverTime: at(),
    platforms: [{
      platform: "youtube",
      state: acc?.state ?? "disconnected",
      account: acc?.account_title ?? null,
      lastGoodReadAt: acc?.last_good_read_at ?? null,
      lastAttemptAt: acc?.last_attempt_at ?? null,
      lastError: acc?.last_error ?? null,
      readIntervalMinutes: 15,
      gaps,
    }],
    deletions,
  });
}

async function history({ env, url }: Ctx): Promise<Response> {
  const days = Number(url.searchParams.get("days") ?? 28);
  if (url.searchParams.get("platform") !== "youtube" || ![7, 28, 90].includes(days)) {
    throw new ApiError(400, "bad_request", "Expected platform=youtube and days=7, 28 or 90.");
  }
  const a = await latest(env, "analytics");
  const rows: { date: string }[] = (a?.rows ?? []).slice(-days);
  return json({ platform: "youtube", readAt: a?.readAt ?? null, rows, lastReportedDate: a?.rows?.at(-1)?.date ?? null });
}

async function connect({ env, request, device }: Ctx): Promise<Response> {
  const state = randomToken();
  const verifier = randomToken();
  await run(env, "INSERT INTO oauth_states (state, device_id, verifier, expires_at, platform) VALUES (?, ?, ?, ?, 'youtube')", state, device.id, verifier, at(10 * 60_000));
  const authUrl = "https://accounts.google.com/o/oauth2/v2/auth?" + new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${new URL(request.url).origin}/v1/youtube/callback`,
    response_type: "code",
    scope: SCOPES,
    access_type: "offline",
    prompt: "consent",
    state,
    code_challenge: b64url(await sha256(verifier)),
    code_challenge_method: "S256",
  });
  return json({ authUrl });
}

async function callback({ env, request, url, exec }: Ctx): Promise<Response> {
  const fail = (msg: string, status = 400) => page("YouTube not connected", `<h1>YouTube was not connected</h1><p>${msg}</p>`, status);
  const state = url.searchParams.get("state");
  // Single use: claiming marks the row used. It stays until the account is written, so a delete in between (which clears states) stops the write.
  const row = state && (await one<{ device_id: string; verifier: string }>(env, "UPDATE oauth_states SET used_at=?1 WHERE state=?2 AND used_at IS NULL AND expires_at>?1 RETURNING device_id, verifier", at(), state));
  if (!row || !(await one(env, "SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL", row.device_id))) {
    return fail("This sign-in link has expired or was already used. Start again from the app.");
  }
  const code = url.searchParams.get("code");
  if (url.searchParams.get("error") || !code) return fail("Google did not give access. Start again from the app if that was a mistake.");

  const r = await fetch(TOKEN_URL, {
    method: "POST",
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      code,
      code_verifier: row.verifier,
      grant_type: "authorization_code",
      redirect_uri: `${new URL(request.url).origin}/v1/youtube/callback`,
    }),
  });
  const t: { access_token?: string; refresh_token?: string; expires_in?: number } = r.ok ? await r.json() : {};
  if (!t.access_token || !t.refresh_token) return fail("Google did not return the access the app needs. Start again from the app.", 502);

  // A fresh start with a new generation id: readings from a previous (possibly different) channel are dropped and any
  // read still in flight for the old generation can no longer write. All of it is conditional on the state row
  // surviving, so a delete-all that ran while Google was answering wins.
  const [, written] = await env.DB.batch([
    env.DB.prepare("DELETE FROM readings WHERE platform='youtube' AND EXISTS (SELECT 1 FROM oauth_states WHERE state=?)").bind(state),
    env.DB.prepare(`INSERT INTO accounts (platform, refresh_token_enc, access_token_enc, access_expires_at, state, connected_at, connection_id)
      SELECT 'youtube', ?1, ?2, ?3, 'connected', ?4, ?5 WHERE EXISTS (SELECT 1 FROM oauth_states WHERE state=?6)
      ON CONFLICT(platform) DO UPDATE SET refresh_token_enc=?1, access_token_enc=?2, access_expires_at=?3, state='connected',
        connected_at=?4, connection_id=?5, account_title=NULL, account_title_at=NULL, first_failure_at=NULL, last_good_read_at=NULL, last_attempt_at=NULL, last_error=NULL`)
      .bind(await seal(env, t.refresh_token), await seal(env, t.access_token), at((t.expires_in ?? 3600) * 1000), at(), crypto.randomUUID(), state),
    env.DB.prepare("DELETE FROM oauth_states WHERE state=?").bind(state),
  ]);
  if (!written.meta.changes) return fail("The data was deleted while you were signing in. Start again from the app.", 409);
  exec.waitUntil(readYouTube(env));
  return page("YouTube connected", "<h1>YouTube connected.</h1><p>You can close this tab.</p>");
}

const disconnect: Handler = async ({ env }) => (await wipe(env, "youtube"), json({ ok: true }));
const deleteAll: Handler = async ({ env }) => {
  for (const p of PLATFORMS) await wipe(env, p);
  return json({ ok: true });
};

async function refresh({ env }: Ctx): Promise<Response> {
  // At most one refresh per 60 s across all callers: the upsert only succeeds when the stored time is older.
  const r = await run(env, "INSERT INTO meta (key, value) VALUES ('refresh_at', ?1) ON CONFLICT(key) DO UPDATE SET value=?1 WHERE value<?2", at(), ago(60_000));
  if (!r.meta.changes) throw new ApiError(429, "rate_limited", "Refreshed less than a minute ago.");
  await readYouTube(env);
  return json(await buildSummary(env));
}

const open = new Set(["GET /privacy", "GET /v1/youtube/callback", "POST /v1/devices/enrol"]);
const routes: Record<string, Handler> = {
  "GET /privacy": async () => privacy(),
  "GET /v1/youtube/callback": callback,
  "POST /v1/devices/enrol": enrol,
  "POST /v1/devices/pair": pair,
  "GET /v1/devices": devices,
  "POST /v1/devices/revoke": revoke,
  "GET /v1/status": status,
  "GET /v1/summary": async ({ env }) => json(await buildSummary(env)),
  "GET /v1/history": history,
  "POST /v1/youtube/connect": connect,
  "POST /v1/youtube/disconnect": disconnect,
  "POST /v1/refresh": refresh,
  "POST /v1/delete-all": deleteAll,
};

export default {
  async fetch(request, env, exec) {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/^\/v1\/devices\/[^/]+\/revoke$/, "/v1/devices/revoke");
      const key = `${request.method} ${path}`;
      const handler = routes[key];
      if (!handler) throw new ApiError(404, "not_found", "No such route.");
      const device = open.has(key) ? { id: "" } : await authenticate(request, env);
      return await handler({ env, request, url, exec, device });
    } catch (e) {
      if (e instanceof ApiError) return json({ error: e.code, message: e.message }, e.status);
      console.error("unhandled error", e instanceof Error ? e.name : "unknown"); // name only: messages could carry request data
      return json({ error: "internal", message: "Something went wrong." }, 500);
    }
  },

  async scheduled(_event, env, exec) {
    exec.waitUntil(cron(env));
  },
} satisfies ExportedHandler<Env>;

async function cron(env: Env) {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM readings WHERE read_at<?").bind(ago(100 * DAY)),
    // Count readings hold titles; YouTube policy allows non-statistics for 30 days only.
    env.DB.prepare("DELETE FROM readings WHERE kind='counts' AND read_at<?").bind(ago(30 * DAY)),
    env.DB.prepare("DELETE FROM deletions WHERE at<?").bind(ago(100 * DAY)),
    env.DB.prepare("DELETE FROM oauth_states WHERE expires_at<?").bind(at()),
    env.DB.prepare("DELETE FROM enrol_codes WHERE expires_at<?").bind(ago(DAY)),
  ]);
  // Channel titles are non-statistics: cleared 30 days after they were last read, even if the token still renews.
  await run(env, "UPDATE accounts SET account_title=NULL, account_title_at=NULL WHERE account_title_at<?", ago(30 * DAY));
  const stale = await one(env, "SELECT 1 FROM accounts WHERE platform='youtube' AND first_failure_at<?", ago(30 * DAY));
  if (stale) await wipe(env, "youtube", false);
  await readYouTube(env);
}

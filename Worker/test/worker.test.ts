import { env } from "cloudflare:workers";
import { applyD1Migrations, createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, expect, it, vi } from "vitest";
import worker from "../src/index";

const e = env as unknown as Env & { TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1] };
const SECRETS = ["RT1", "AT1", "AT2", "test-client-secret"];

// ---- A fake Google, recording every call ----

interface Call { url: URL; body: URLSearchParams; auth: string | null }
let calls: Call[];
let google: { refresh: "ok" | "invalid_grant"; channels: number; dailyRows: number };

const ymd = (d: Date) => d.toISOString().slice(0, 10);
const LAST_DAY = "2026-11-12";
const dailyRows = (n: number) =>
  Array.from({ length: n }, (_, i) => [ymd(new Date(Date.parse(LAST_DAY) - (n - 1 - i) * 86_400_000)), 10, 20, 3, 1]);
const HEADERS = (dim: boolean) => [...(dim ? [{ name: "day" }] : []), ...["views", "estimatedMinutesWatched", "subscribersGained", "subscribersLost"].map((name) => ({ name }))];
const reply = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });

function fakeGoogle(input: string | URL | Request, init?: RequestInit) {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
  const headers = new Headers(init?.headers);
  calls.push({ url, body: new URLSearchParams(init?.body as URLSearchParams | undefined), auth: headers.get("authorization") });
  const grant = calls.at(-1)!.body.get("grant_type");
  switch (url.origin + url.pathname) {
    case "https://oauth2.googleapis.com/token":
      if (grant === "authorization_code") return reply({ access_token: "AT1", refresh_token: "RT1", expires_in: 3600 });
      return google.refresh === "ok" ? reply({ access_token: "AT2", expires_in: 3600 }) : reply({ error: "invalid_grant", error_description: "Token revoked" }, 400);
    case "https://oauth2.googleapis.com/revoke":
      return reply({});
    case "https://www.googleapis.com/youtube/v3/channels":
      if (google.channels !== 200) return reply({ error: { message: "nope" } }, google.channels);
      return reply({ items: [{ snippet: { title: "Junior Nkana Bassi" }, statistics: { subscriberCount: "4810", hiddenSubscriberCount: false }, contentDetails: { relatedPlaylists: { uploads: "UU1" } } }] });
    case "https://www.googleapis.com/youtube/v3/playlistItems":
      return reply({ items: [{ contentDetails: { videoId: "vid1" } }] });
    case "https://www.googleapis.com/youtube/v3/videos":
      return reply({ items: [{ snippet: { title: "Latest video", publishedAt: "2026-11-10T12:00:00Z" }, statistics: { viewCount: "999" } }] });
    case "https://youtubeanalytics.googleapis.com/v2/reports":
      // The window total is deliberately not the sum of the daily rows.
      return url.searchParams.has("dimensions")
        ? reply({ columnHeaders: HEADERS(true), rows: dailyRows(google.dailyRows) })
        : reply({ columnHeaders: HEADERS(false), rows: [[1234, 5678, 90, 4]] });
  }
  return reply({}, 404);
}

// ---- Helpers ----

async function req(path: string, opts: { method?: string; body?: unknown; token?: string } = {}) {
  const ctx = createExecutionContext();
  const res = await worker.fetch(
    new Request(`https://social.test${path}`, {
      method: opts.method ?? (opts.body ? "POST" : "GET"),
      headers: { ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}), "content-type": "application/json" },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    }) as Request<unknown, IncomingRequestCfProperties>,
    e,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return res;
}
const post = (path: string, token: string, body?: unknown) => req(path, { method: "POST", token, body });
const get = async (path: string, token: string) => (await req(path, { token })).json<any>();

async function enrolDevice(code = e.ENROL_CODE, name = "Test Mac") {
  const res = await req("/v1/devices/enrol", { body: { code, name, kind: "mac" } });
  return { res, ...(res.ok ? await res.clone().json<{ deviceId: string; token: string }>() : { deviceId: "", token: "" }) };
}

async function connect(token: string) {
  const { authUrl } = await (await post("/v1/youtube/connect", token)).json<{ authUrl: string }>();
  const state = new URL(authUrl).searchParams.get("state")!;
  return { authUrl: new URL(authUrl), state, callback: (s = state) => req(`/v1/youtube/callback?code=authcode&state=${s}`) };
}

async function connected() {
  const { token, deviceId } = await enrolDevice();
  const c = await connect(token);
  const res = await c.callback();
  expect(res.status).toBe(200);
  return { token, deviceId, ...c };
}

const allText = async () =>
  JSON.stringify((await e.DB.prepare("SELECT payload FROM readings").all()).results) +
  JSON.stringify((await e.DB.prepare("SELECT last_error FROM accounts").all()).results);

beforeAll(() => applyD1Migrations(e.DB, e.TEST_MIGRATIONS));
beforeEach(async () => {
  await e.DB.batch(["devices", "enrol_codes", "oauth_states", "accounts", "readings", "deletions", "meta"].map((t) => e.DB.prepare(`DELETE FROM ${t}`)));
  calls = [];
  google = { refresh: "ok", channels: 200, dailyRows: 30 };
  vi.stubGlobal("fetch", vi.fn(fakeGoogle));
});
afterEach(() => vi.unstubAllGlobals());

// ---- Devices and auth ----

it("accepts the deploy code once only", async () => {
  const first = await enrolDevice();
  expect(first.res.status).toBe(200);
  expect(first.token.length).toBeGreaterThan(40);
  const stored = await e.DB.prepare("SELECT token_hash FROM devices").all<{ token_hash: string }>();
  expect(JSON.stringify(stored.results)).not.toContain(first.token);

  const again = await enrolDevice();
  expect(again.res.status).toBe(403);
  expect((await enrolDevice("wrong-code")).res.status).toBe(403);
  expect((await req("/v1/devices/enrol", { body: { code: "x", name: "", kind: "toaster" } })).status).toBe(400);
});

it("pairing codes are single use and expire", async () => {
  const { token } = await enrolDevice();
  const { code, expiresAt } = await (await post("/v1/devices/pair", token)).json<{ code: string; expiresAt: string }>();
  expect(Date.parse(expiresAt) - Date.now()).toBeGreaterThan(9 * 60_000);

  const phone = await enrolDevice(code, "iPhone");
  expect(phone.res.status).toBe(200);
  expect((await enrolDevice(code, "Other")).res.status).toBe(403);

  const second = await (await post("/v1/devices/pair", token)).json<{ code: string }>();
  await e.DB.prepare("UPDATE enrol_codes SET expires_at=?").bind(new Date(Date.now() - 1000).toISOString()).run();
  expect((await enrolDevice(second.code, "Late")).res.status).toBe(403);

  const list = await get("/v1/devices", token);
  expect(list.devices.map((d: any) => [d.name, d.current])).toEqual([["Test Mac", true], ["iPhone", false]]);
});

it("returns 401 without a token or with a revoked one, and 404 JSON for unknown routes", async () => {
  expect((await req("/v1/summary")).status).toBe(401);
  expect((await req("/v1/summary", { token: "nonsense" })).status).toBe(401);

  const mac = await enrolDevice();
  const { code } = await (await post("/v1/devices/pair", mac.token)).json<{ code: string }>();
  const phone = await enrolDevice(code, "iPhone");
  expect((await get("/v1/summary", phone.token)).youtube).toBeNull();

  expect((await post(`/v1/devices/${phone.deviceId}/revoke`, mac.token)).status).toBe(200);
  const res = await req("/v1/summary", { token: phone.token });
  expect(res.status).toBe(401);
  expect(await res.json()).toMatchObject({ error: "unauthorized" });

  const missing = await req("/v1/nothing");
  expect(missing.status).toBe(404);
  expect(await missing.json()).toMatchObject({ error: "not_found" });
});

// ---- OAuth ----

it("builds a PKCE consent URL tied to the device and rejects bad or reused state", async () => {
  const { token } = await enrolDevice();
  const c = await connect(token);
  const p = c.authUrl.searchParams;
  expect(c.authUrl.origin + c.authUrl.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
  expect(p.get("code_challenge_method")).toBe("S256");
  expect(p.get("access_type")).toBe("offline");
  expect(p.get("prompt")).toBe("consent");
  expect(p.get("redirect_uri")).toBe("https://social.test/v1/youtube/callback");
  expect(p.get("scope")).toBe("https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/yt-analytics.readonly");

  const bad = await req("/v1/youtube/callback?code=abc&state=bogus");
  expect(bad.status).toBe(400);
  expect(await bad.text()).toContain("was not connected");
  expect(calls.length).toBe(0); // nothing was sent to Google

  expect((await c.callback()).status).toBe(200);
  const exchange = calls.find((x) => x.body.get("grant_type") === "authorization_code")!;
  expect(exchange.body.get("code_verifier")).toBeTruthy();
  expect(exchange.body.get("redirect_uri")).toBe("https://social.test/v1/youtube/callback");

  expect((await c.callback()).status).toBe(400); // single use

  const expired = await connect(token);
  await e.DB.prepare("UPDATE oauth_states SET expires_at=?").bind(new Date(Date.now() - 1000).toISOString()).run();
  expect((await expired.callback()).status).toBe(400);
});

// ---- Reads ----

it("stores counts and the 28-day window exactly as YouTube returned them", async () => {
  const { token } = await connected();
  const s = await get("/v1/summary", token);
  expect(s.youtube).toMatchObject({
    state: "connected",
    channelTitle: "Junior Nkana Bassi",
    subscriberCount: 4810,
    subscriberCountHidden: false,
    newestVideo: { id: "vid1", title: "Latest video", publishedAt: "2026-11-10T12:00:00Z", viewCount: 999, url: "https://www.youtube.com/watch?v=vid1" },
    // 1234 etc. are the mocked total query; summing 28 daily rows of 10 views would give 280.
    window: { startDate: "2026-10-16", endDate: LAST_DAY, partial: false, views: 1234, estimatedMinutesWatched: 5678, subscribersGained: 90, subscribersLost: 4 },
  });
  expect(s.youtube.countsReadAt).toBeTruthy();
  expect(s.youtube.window.readAt).toBeTruthy();

  const totals = calls.filter((c) => c.url.pathname === "/v2/reports" && !c.url.searchParams.has("dimensions"));
  expect(totals).toHaveLength(1);
  expect(totals[0].url.searchParams.get("startDate")).toBe("2026-10-16");
  expect(totals[0].url.searchParams.get("endDate")).toBe(LAST_DAY);
  expect(calls.filter((c) => c.auth).every((c) => c.auth === "Bearer AT1")).toBe(true);

  const h = await get("/v1/history?platform=youtube&days=7", token);
  expect(h.rows).toHaveLength(7);
  expect(h.rows.at(-1)).toEqual({ date: LAST_DAY, views: 10, estimatedMinutesWatched: 20, subscribersGained: 3, subscribersLost: 1 });
  expect(h.lastReportedDate).toBe(LAST_DAY);
  expect((await req("/v1/history?platform=youtube&days=5", { token })).status).toBe(400);

  const st = await get("/v1/status", token);
  expect(st.platforms[0]).toMatchObject({ platform: "youtube", state: "connected", account: "Junior Nkana Bassi", lastError: null, readIntervalMinutes: 15, gaps: [] });

  // Tokens are encrypted at rest and never in readings.
  const row = await e.DB.prepare("SELECT refresh_token_enc, access_token_enc FROM accounts").first<Record<string, string>>();
  expect(JSON.stringify(row)).not.toMatch(/RT1|AT1/);
  const text = await allText();
  for (const secret of SECRETS) expect(text).not.toContain(secret);
});

it("marks the window partial when YouTube returns fewer than 28 daily rows", async () => {
  google.dailyRows = 20;
  const { token } = await connected();
  expect((await get("/v1/summary", token)).youtube.window).toMatchObject({ partial: true, views: 1234 });
});

it("reads analytics once a day, not on every refresh", async () => {
  const { token } = await connected();
  const analytics = () => calls.filter((c) => c.url.pathname === "/v2/reports").length;
  expect(analytics()).toBe(2);
  await e.DB.prepare("DELETE FROM meta WHERE key='refresh_at'").run();
  expect((await post("/v1/refresh", token)).status).toBe(200);
  expect(analytics()).toBe(2);
});

it("records only the status of a failed read, never a token", async () => {
  google.channels = 403;
  const { token } = await connected();
  const st = (await get("/v1/status", token)).platforms[0];
  expect(st.lastError).toBe("http 403");
  expect(st.gaps).toHaveLength(1);
  const rows = (await e.DB.prepare("SELECT ok, payload FROM readings").all<{ ok: number; payload: string }>()).results;
  expect(rows).toEqual([{ ok: 0, payload: '{"error":"http 403"}' }]);
  const text = await allText();
  for (const secret of SECRETS) expect(text).not.toContain(secret);
});

it("keeps the data and asks to reconnect on invalid_grant", async () => {
  const { token } = await connected();
  await e.DB.prepare("UPDATE accounts SET access_expires_at=?").bind(new Date(Date.now() + 60_000).toISOString()).run(); // inside the 5 minute renewal window
  google.refresh = "invalid_grant";

  const res = await post("/v1/refresh", token);
  expect(res.status).toBe(200);
  const s = (await res.json<any>()).youtube;
  expect(s.state).toBe("needsReconnect");
  expect(s.subscriberCount).toBe(4810);
  expect(s.window.views).toBe(1234);

  const st = (await get("/v1/status", token)).platforms[0];
  expect(st).toMatchObject({ state: "needsReconnect", lastError: "invalid_grant" });
  const acc = await e.DB.prepare("SELECT first_failure_at FROM accounts").first<{ first_failure_at: string }>();
  expect(acc!.first_failure_at).toBeTruthy();
  for (const secret of SECRETS) expect(await allText()).not.toContain(secret);
});

it("rate limits refresh to once a minute", async () => {
  const { token } = await connected();
  expect((await post("/v1/refresh", token)).status).toBe(200);
  const res = await post("/v1/refresh", token);
  expect(res.status).toBe(429);
  expect(await res.json()).toMatchObject({ error: "rate_limited" });
});

// ---- Deletion and retention ----

it("disconnect revokes at Google, deletes everything and records a deletion", async () => {
  const { token } = await connected();
  expect((await post("/v1/youtube/disconnect", token)).status).toBe(200);

  const revoke = calls.find((c) => c.url.pathname === "/revoke")!;
  expect(revoke.body.get("token")).toBe("RT1");
  expect((await e.DB.prepare("SELECT COUNT(*) AS n FROM accounts").first<{ n: number }>())!.n).toBe(0);
  expect((await e.DB.prepare("SELECT COUNT(*) AS n FROM readings").first<{ n: number }>())!.n).toBe(0);

  const st = await get("/v1/status", token);
  expect(st.platforms[0]).toMatchObject({ state: "disconnected", account: null });
  expect(st.deletions).toHaveLength(1);
  expect(st.deletions[0].platform).toBe("youtube");
  expect((await get("/v1/summary", token)).youtube).toBeNull();
});

it("delete-all wipes every platform but keeps devices enrolled", async () => {
  const { token } = await connected();
  expect((await post("/v1/delete-all", token)).status).toBe(200);
  expect(calls.some((c) => c.url.pathname === "/revoke")).toBe(true);
  expect((await get("/v1/summary", token)).youtube).toBeNull();
  expect((await get("/v1/devices", token)).devices).toHaveLength(1);
});

it("the cron trims old readings and purges YouTube data 30 days after the first failure", async () => {
  const { token } = await connected();
  const old = new Date(Date.now() - 101 * 86_400_000).toISOString();
  await e.DB.prepare("INSERT INTO readings (platform, kind, read_at, ok, payload) VALUES ('youtube', 'counts', ?, 1, '{}')").bind(old).run();

  const run = async () => {
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController(), e, ctx);
    await waitOnExecutionContext(ctx);
  };
  await run();
  expect((await e.DB.prepare("SELECT COUNT(*) AS n FROM readings WHERE read_at=?").bind(old).first<{ n: number }>())!.n).toBe(0);
  expect((await get("/v1/summary", token)).youtube.subscriberCount).toBe(4810);

  await e.DB.prepare("UPDATE accounts SET state='needsReconnect', first_failure_at=?").bind(new Date(Date.now() - 31 * 86_400_000).toISOString()).run();
  await run();
  expect((await get("/v1/summary", token)).youtube).toBeNull();
  expect((await get("/v1/status", token)).deletions).toHaveLength(1);
  expect(calls.some((c) => c.url.pathname === "/revoke")).toBe(false); // the token was already dead
});

it("serves a public privacy policy", async () => {
  const res = await req("/privacy");
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("https://www.youtube.com/t/terms");
  expect(html).toContain("https://policies.google.com/privacy");
});

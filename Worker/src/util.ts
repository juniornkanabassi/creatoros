export const DAY = 86_400_000;
export const at = (ms = 0) => new Date(Date.now() + ms).toISOString();
export const ago = (ms: number) => at(-ms);

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

export const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

export async function readBody(request: Request): Promise<Record<string, unknown>> {
  const body: unknown = await request.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new ApiError(400, "bad_request", "Expected a JSON object.");
  }
  return body as Record<string, unknown>;
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const b64url = (b: Uint8Array) => b64(b).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
export const randomToken = (bytes = 32) => b64url(crypto.getRandomValues(new Uint8Array(bytes)));

export const sha256 = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
export const sha256Hex = async (s: string) => [...(await sha256(s))].map((x) => x.toString(16).padStart(2, "0")).join("");

// Compare digests, not the raw strings, so length does not leak either.
export async function safeEqual(a: string, b: string) {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

const aesKey = (env: Env) => crypto.subtle.importKey("raw", unb64(env.TOKEN_KEY), "AES-GCM", false, ["encrypt", "decrypt"]);

// AES-GCM with a fresh 12-byte IV per value; stored as base64(iv + ciphertext).
export async function seal(env: Env, text: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await aesKey(env), new TextEncoder().encode(text)));
  return b64(Uint8Array.from([...iv, ...ct]));
}

export async function unseal(env: Env, blob: string) {
  const raw = unb64(blob);
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.slice(0, 12) }, await aesKey(env), raw.slice(12)));
}

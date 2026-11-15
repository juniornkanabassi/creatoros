// Secrets (wrangler secret put); the D1 binding comes from the generated worker-configuration.d.ts.
interface Env {
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  TOKEN_KEY: string;
  ENROL_CODE: string;
}

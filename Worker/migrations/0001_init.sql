-- Times are ISO 8601 UTC strings (always the same 24-character form, so they sort as text).
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE enrol_codes (
  code_hash TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('deploy', 'pair')),
  expires_at TEXT NOT NULL,
  used_at TEXT
);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  verifier TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  platform TEXT NOT NULL,
  used_at TEXT
);

CREATE TABLE accounts (
  platform TEXT PRIMARY KEY,
  refresh_token_enc TEXT NOT NULL,
  access_token_enc TEXT,
  access_expires_at TEXT,
  state TEXT NOT NULL CHECK (state IN ('connected', 'needsReconnect')),
  account_title TEXT,
  account_title_at TEXT,
  -- Generation id, new at every connect. Reads write only while their generation is still the stored one.
  connection_id TEXT NOT NULL,
  connected_at TEXT NOT NULL,
  first_failure_at TEXT,
  last_good_read_at TEXT,
  last_attempt_at TEXT,
  last_error TEXT
);

CREATE TABLE readings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  platform TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('counts', 'analytics')),
  read_at TEXT NOT NULL,
  ok INTEGER NOT NULL,
  payload TEXT NOT NULL,
  connection_id TEXT NOT NULL
);
CREATE INDEX readings_lookup ON readings (platform, kind, ok, read_at);

CREATE TABLE deletions (
  platform TEXT NOT NULL,
  at TEXT NOT NULL
);

-- refresh_at (last /v1/refresh), deploy_code_used.
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

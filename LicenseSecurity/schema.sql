-- Fresh D1 database schema (run once on a new database)
CREATE TABLE IF NOT EXISTS licenses (
  id TEXT PRIMARY KEY,
  key_hash TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active',
  expires_at INTEGER,
  max_devices INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  license_id TEXT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active',
  app_version TEXT NOT NULL DEFAULT '',
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  public_key TEXT
);
CREATE INDEX IF NOT EXISTS idx_devices_license ON devices(license_id, status);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen DESC);
CREATE TABLE IF NOT EXISTS license_challenges (
  id TEXT PRIMARY KEY,
  challenge_hash TEXT NOT NULL UNIQUE,
  device_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('register','verify')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_license_challenges_device_time ON license_challenges(device_id, created_at);
CREATE INDEX IF NOT EXISTS idx_license_challenges_expiry ON license_challenges(expires_at);

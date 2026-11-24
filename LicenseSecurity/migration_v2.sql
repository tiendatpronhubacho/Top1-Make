-- Migration for the current production database.
-- public_key was already added to devices in the user's D1 database.
-- Do NOT run ALTER TABLE devices ADD COLUMN public_key again.
CREATE TABLE IF NOT EXISTS license_challenges (
  id TEXT PRIMARY KEY,
  challenge_hash TEXT NOT NULL UNIQUE,
  device_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('register','verify')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_license_challenges_device_time
ON license_challenges(device_id, created_at);
CREATE INDEX IF NOT EXISTS idx_license_challenges_expiry
ON license_challenges(expires_at);

-- schema: raw for raw data
CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.search_results_json (
  run_id         TEXT        NOT NULL,      -- YYYY-MM-DD-HHMMSS you used in blob path
  query          TEXT        NOT NULL,
  blob_path      TEXT        NOT NULL,
  fetched_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload        JSONB       NOT NULL
);

CREATE TABLE IF NOT EXISTS raw.place_metadata_json (
  run_id         TEXT        NOT NULL,
  place_id       TEXT        NOT NULL,
  blob_path      TEXT        NOT NULL,
  fetched_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload        JSONB       NOT NULL,
  PRIMARY KEY (run_id, place_id, blob_path)
);

CREATE TABLE IF NOT EXISTS raw.place_reviews_json (
  run_id         TEXT        NOT NULL,
  place_id       TEXT        NOT NULL,
  page_no        INT         NOT NULL,      -- from reviews-0001.json => 1, etc.
  blob_path      TEXT        NOT NULL,
  fetched_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload        JSONB       NOT NULL,      -- full array for that page
  PRIMARY KEY (run_id, place_id, page_no, blob_path)
);

-- schema: core, curated results from raw data
CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.dim_place (
  place_id         TEXT PRIMARY KEY,
  data_id          TEXT,
  name             TEXT,
  address          TEXT,
  lat              DOUBLE PRECISION,
  lon              DOUBLE PRECISION,
  price_raw        TEXT,
  rating_avg       NUMERIC(3,2),
  review_count     INT,
  types            TEXT[],                   -- e.g., ["Coffee shop","Cafe"]
  phone            TEXT,
  website          TEXT,
  open_state       TEXT,                     -- e.g., "Open · Closes 1 a.m."
  hours_json       JSONB,                    -- operating_hours object
  service_options  JSONB,                    -- dine_in, takeout, delivery booleans
  extensions       JSONB,                    -- keep the rich bits
  first_seen_at    TIMESTAMPTZ,
  last_refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.fact_review (
  place_id         TEXT        NOT NULL REFERENCES core.dim_place(place_id),
  review_id        TEXT        NOT NULL,
  reviewer_id      TEXT,
  reviewer_name    TEXT,
  rating           SMALLINT,
  text             TEXT,
  iso_date         TIMESTAMPTZ,
  edited_iso_date  TIMESTAMPTZ,
  thumbs_up        INT,
  response_text    TEXT,
  response_iso_date TIMESTAMPTZ,
  images_count     INT,
  source           TEXT        NOT NULL DEFAULT 'google-serpapi',
  PRIMARY KEY(place_id, review_id)
);

CREATE INDEX IF NOT EXISTS idx_fact_review_place_time
  ON core.fact_review(place_id, iso_date DESC);

#!/bin/zsh
# Sourced by the release scripts: R2 (bucket mrrcalendar-downloads, served at
# https://downloads.mrrcalendar.com) over its S3 API with curl --aws-sigv4,
# and the Infisical reader. Credentials come from Infisical `agents`
# /cloudflare (R2_S3_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY). They
# stay in shell variables and reach curl through stdin (-K -), never argv.

R2_BUCKET=mrrcalendar-downloads
PUBLIC_BASE=https://downloads.mrrcalendar.com

sec() {
  infisical secrets get "$2" --path "$1" \
    --projectId 67596dbd-6bef-4d36-96db-426716df1c81 --env prod \
    --domain https://infisical.amorem.cloud/api --plain --silent
}

r2_login() {
  [[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] && return
  R2_S3_ENDPOINT=$(sec /cloudflare R2_S3_ENDPOINT)
  R2_ACCESS_KEY_ID=$(sec /cloudflare R2_ACCESS_KEY_ID)
  R2_SECRET_ACCESS_KEY=$(sec /cloudflare R2_SECRET_ACCESS_KEY)
  [[ -n "$R2_S3_ENDPOINT" && -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" ]] || { echo "R2 credentials missing in Infisical" >&2; return 1; }
}

r2_curl() {
  r2_login
  printf 'user = "%s:%s"\n' "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" \
    | curl -K - --aws-sigv4 "aws:amz:auto:s3" -fsS "$@"
}

# Keys in URLs: Sparkle deltas may carry spaces in their names.
url_key() { print -r -- "${1// /%20}"; }

# r2_put <file> <key> <content-type> <cache-control>
r2_put() {
  r2_login
  r2_curl -X PUT -H "Content-Type: $3" -H "Cache-Control: $4" --upload-file "$1" "$R2_S3_ENDPOINT/$R2_BUCKET/$(url_key "$2")" -o /dev/null
  echo "Uploaded $PUBLIC_BASE/$(url_key "$2")"
}

r2_delete() {
  r2_login
  r2_curl -X DELETE "$R2_S3_ENDPOINT/$R2_BUCKET/$(url_key "$1")" -o /dev/null
  echo "Deleted $PUBLIC_BASE/$(url_key "$1")"
}

# Public object exists?
public_exists() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -I "$PUBLIC_BASE/$(url_key "$1")")" == 200 ]]
}

IMMUTABLE="public, max-age=31536000, immutable"
SHORT="public, max-age=300"

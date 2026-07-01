#!/usr/bin/env bash
#
# calc-pipeline.sh — drive a remote analyzer end-to-end from scanner FSGs.
#
# Phase 1 (per repo FSG): POST gzip(FSG) -> /analyzer/calc-efsg, store gzip(eFSG).
# Phase 2 (once, after all): POST /analyzer/restart, then POST /analyzer/calc-system
#   with {"efsgs":[<url>, ...]}. The analyzer GETs each URL itself (ADR-023 pull
#   contract), so the eFSGs must live somewhere it can reach. Two backends:
#     BLOB_BACKEND=s3    (default) aws s3 cp + presign  — S3 or MinIO (S3_ENDPOINT)
#     BLOB_BACKEND=local serve WORK_DIR over http       — analyzer GETs localhost
#
# The analyzer is stateless: calc-efsg is a pure gzip(FSG)->gzip(eFSG) function,
# calc-system a pure [uri]->bundle function. This script is the BFF Analyze path
# (apps/bff/{enrich,analysis}.go) reduced to curl, with the blob backend standing
# in for the BFF's eFSG blob endpoint.
#
# Deps: curl, jq, xxd. s3 backend also needs aws; local backend needs python3.
#
# Usage:
#   ANALYZER_URL=http://localhost:3031 BLOB_BACKEND=local \
#     ./calc-pipeline.sh [SCANS_DIR]
#   ANALYZER_URL=https://analyzer.example.com S3_BUCKET=my-efsg \
#     ./calc-pipeline.sh ./scans
#   # MinIO: BLOB_BACKEND=s3 S3_BUCKET=flowz-artifacts \
#   #   S3_ENDPOINT=http://localhost:19000 AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
#
# Env (all overridable):
#   ANALYZER_URL     (required)  base URL of the analyzer, e.g. http://localhost:3031
#   SCANS_DIR        (arg/$1, default ./scans)  dir of gzipped FSGs (*.json.gz)
#   WORK_DIR         (default ./efsg-out)        where gzip(eFSG)s are written
#   CACHE_DIR        (default "")                content-addressed eFSG cache; when
#                                                set, an FSG whose bytes are unchanged
#                                                reuses its eFSG and skips the analyzer.
#                                                Namespace it by analyzer version (the
#                                                CI cache key includes the image digest).
#   OUT              (default ./arch-bundle.json) calc-system bundle output
#   CURL_OPTS        (default "")                extra curl flags (e.g. auth header)
#   BLOB_BACKEND     (default s3)                s3 | local
#   --- s3 backend ---
#   S3_BUCKET        (required for s3)           bucket eFSGs are uploaded to
#   S3_PREFIX        (default flowz-efsg/<utc-ts>)  key prefix in the bucket
#   S3_ENDPOINT      (default "")                --endpoint-url (set for MinIO)
#   PRESIGN_EXPIRY   (default 14400)             presigned-URL lifetime, seconds
#   --- local backend ---
#   LOCAL_BLOB_HOST  (default localhost)         host the analyzer dials back on
#   LOCAL_BLOB_PORT  (default 8077)              port the static server binds
#
set -euo pipefail

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*" >&2; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

ANALYZER_URL="${ANALYZER_URL:?set ANALYZER_URL to the analyzer base URL}"
ANALYZER_URL="${ANALYZER_URL%/}"
SCANS_DIR="${1:-${SCANS_DIR:-./scans}}"
WORK_DIR="${WORK_DIR:-./efsg-out}"
OUT="${OUT:-./arch-bundle.json}"
CURL_OPTS="${CURL_OPTS:-}"
CACHE_DIR="${CACHE_DIR:-}"
BLOB_BACKEND="${BLOB_BACKEND:-s3}"

for bin in curl jq xxd; do
  command -v "$bin" >/dev/null 2>&1 || { err "missing dependency: $bin"; exit 1; }
done

shopt -s nullglob
fsgs=("$SCANS_DIR"/*.json.gz)
if [ ${#fsgs[@]} -eq 0 ]; then
  err "no *.json.gz FSGs found in $SCANS_DIR"
  err "(produce them with: flowz scan <repo> -o $SCANS_DIR/<name>.json.gz)"
  exit 1
fi
mkdir -p "$WORK_DIR"

# Liveness: a quick GET on / (same probe the BFF uses; <500 == reachable).
code=$(curl -s -o /dev/null -w '%{http_code}' $CURL_OPTS "$ANALYZER_URL/" || true)
if [ -z "$code" ] || [ "$code" -ge 500 ]; then
  err "analyzer at $ANALYZER_URL not reachable (GET / -> ${code:-no response})"; exit 1
fi
info "analyzer reachable at $ANALYZER_URL (GET / -> $code)"

# --- Phase 1: calc-efsg per FSG (content-addressed cache when CACHE_DIR set) ---
# The cache holds gzip(eFSG) files named by the sha256 of the *decompressed* FSG
# (the analyzer's input). A byte-identical FSG => cache hit => the analyzer call
# is skipped. Callers must namespace CACHE_DIR by analyzer version (the CI cache
# key includes the image digest) so an analyzer bump never reuses stale eFSGs.
ids=(); efsgs=(); hashes=(); hits=0; miss=0
[ -n "$CACHE_DIR" ] && mkdir -p "$CACHE_DIR"
info "phase 1: enriching ${#fsgs[@]} FSG(s) via calc-efsg${CACHE_DIR:+ (cache: $CACHE_DIR)}"
for fsg in "${fsgs[@]}"; do
  id="$(basename "$fsg")"; id="${id%.json.gz}"
  efsg="$WORK_DIR/$id.efsg.json.gz"

  h=""
  if [ -n "$CACHE_DIR" ]; then
    h=$(gunzip -c "$fsg" | sha256)
    hashes+=("$h")
    if [ -f "$CACHE_DIR/$h.efsg.json.gz" ]; then
      cp "$CACHE_DIR/$h.efsg.json.gz" "$efsg"
      ids+=("$id"); efsgs+=("$efsg"); hits=$((hits+1))
      ok "  cached   $id (${h:0:12}, $(du -h "$efsg" | cut -f1))"
      continue
    fi
  fi

  http=$(curl -sS $CURL_OPTS -H 'Content-Type: application/gzip' \
    --data-binary "@$fsg" -o "$efsg" -w '%{http_code}' \
    "$ANALYZER_URL/analyzer/calc-efsg") || { err "calc-efsg request failed for $id"; exit 1; }
  if [ "$http" -lt 200 ] || [ "$http" -ge 300 ]; then
    err "calc-efsg returned $http for $id:"; head -c 500 "$efsg" >&2; echo >&2; exit 1
  fi
  if [ "$(head -c2 "$efsg" | xxd -p)" != "1f8b" ]; then
    err "calc-efsg returned 200 but body is not gzip for $id:"; head -c 500 "$efsg" >&2; echo >&2; exit 1
  fi
  [ -n "$CACHE_DIR" ] && cp "$efsg" "$CACHE_DIR/$h.efsg.json.gz"
  ids+=("$id"); efsgs+=("$efsg"); miss=$((miss+1))
  ok "  enriched $id ($(du -h "$efsg" | cut -f1))"
done

# Bound the cache to the current service set: drop eFSGs whose FSG is no longer
# present (a service was renamed, removed, or changed), so the saved cache dir
# tracks today's services rather than growing without limit across runs.
if [ -n "$CACHE_DIR" ]; then
  keep=" ${hashes[*]} "
  for f in "$CACHE_DIR"/*.efsg.json.gz; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"; b="${b%.efsg.json.gz}"
    case "$keep" in *" $b "*) : ;; *) rm -f "$f" ;; esac
  done
  info "phase 1 cache: $hits hit, $miss enriched"
fi

# --- Build eFSG URLs (backend-specific) -----------------------------------
uris=(); blob_pid=""
cleanup() { [ -n "$blob_pid" ] && kill "$blob_pid" 2>/dev/null || true; }
trap cleanup EXIT

case "$BLOB_BACKEND" in
  s3)
    command -v aws >/dev/null 2>&1 || { err "s3 backend needs aws CLI"; exit 1; }
    S3_BUCKET="${S3_BUCKET:?s3 backend needs S3_BUCKET}"
    PRESIGN_EXPIRY="${PRESIGN_EXPIRY:-14400}"
    S3_PREFIX="${S3_PREFIX:-flowz-efsg/$(date -u +%Y%m%dT%H%M%SZ)}"; S3_PREFIX="${S3_PREFIX%/}"
    ep=(); [ -n "${S3_ENDPOINT:-}" ] && ep=(--endpoint-url "$S3_ENDPOINT")
    info "uploading ${#efsgs[@]} eFSG(s) to s3://$S3_BUCKET/$S3_PREFIX/ ${S3_ENDPOINT:+(endpoint $S3_ENDPOINT)}"
    for i in "${!efsgs[@]}"; do
      key="$S3_PREFIX/${ids[$i]}.efsg.json.gz"
      aws "${ep[@]}" s3 cp "${efsgs[$i]}" "s3://$S3_BUCKET/$key" \
        --content-type application/gzip --only-show-errors
      uris+=("$(aws "${ep[@]}" s3 presign "s3://$S3_BUCKET/$key" --expires-in "$PRESIGN_EXPIRY")")
    done
    ;;
  local)
    command -v python3 >/dev/null 2>&1 || { err "local backend needs python3"; exit 1; }
    LOCAL_BLOB_HOST="${LOCAL_BLOB_HOST:-localhost}"
    LOCAL_BLOB_PORT="${LOCAL_BLOB_PORT:-8077}"
    info "serving $WORK_DIR at http://$LOCAL_BLOB_HOST:$LOCAL_BLOB_PORT (analyzer pulls from here)"
    ( cd "$WORK_DIR" && exec python3 -m http.server "$LOCAL_BLOB_PORT" --bind 0.0.0.0 ) >/dev/null 2>&1 &
    blob_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -o /dev/null "http://localhost:$LOCAL_BLOB_PORT/" && break || sleep 0.3
    done
    for i in "${!ids[@]}"; do
      uris+=("http://$LOCAL_BLOB_HOST:$LOCAL_BLOB_PORT/${ids[$i]}.efsg.json.gz")
    done
    ;;
  *)
    err "unknown BLOB_BACKEND: $BLOB_BACKEND (want s3|local)"; exit 1 ;;
esac

# --- Phase 2: restart, then calc-system over all eFSG URLs -----------------
info "phase 2: restart + calc-system over ${#uris[@]} eFSG(s)"
curl -sS $CURL_OPTS -X POST -H 'Content-Type: application/json' \
  -d '{"key":"clear-analyzer"}' "$ANALYZER_URL/analyzer/restart" >/dev/null \
  || { err "restart failed"; exit 1; }

payload=$(printf '%s\n' "${uris[@]}" | jq -R . | jq -s '{efsgs: .}')
http=$(curl -sS $CURL_OPTS -X POST -H 'Content-Type: application/json' \
  -d "$payload" -o "$OUT" -w '%{http_code}' \
  "$ANALYZER_URL/analyzer/calc-system") || { err "calc-system request failed"; exit 1; }
if [ "$http" -lt 200 ] || [ "$http" -ge 300 ]; then
  err "calc-system returned $http:"; head -c 800 "$OUT" >&2; echo >&2; exit 1
fi

ok "done -> $OUT ($(du -h "$OUT" | cut -f1))"
jq -r '"  status: \(.status // "?")  symbols: \(.graph.symbols|length? // 0)  links: \(.graph.links|length? // 0)  flows: \(.flowsList|length? // 0)"' "$OUT" 2>/dev/null \
  || info "(bundle written; not JSON? first bytes:) $(head -c 120 "$OUT")"

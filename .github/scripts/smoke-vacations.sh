#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${EXPECTED_SOURCE_SHA:?EXPECTED_SOURCE_SHA is required}"
: "${CF_ACCESS_CLIENT_ID:?CF_ACCESS_CLIENT_ID is required}"
: "${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET is required}"

if [[ ! "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected source SHA is not a 40-character lowercase hexadecimal value." >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

access_headers=(
  --header "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}"
  --header "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}"
)

header_value() {
  local name="$1" file="$2"
  awk -v wanted="$name" '
    index(tolower($0), tolower(wanted) ":") == 1 {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      value = $0
    }
    END { print value }
  ' "$file"
}

request() {
  local url="$1" headers="$2" body="$3"
  shift 3
  curl --silent --show-error \
    --connect-timeout 10 \
    --max-time 60 \
    --dump-header "$headers" \
    --output "$body" \
    --write-out "%{http_code}" \
    "${access_headers[@]}" \
    "$@" \
    "$url"
}

echo "Waiting for ArgoCD to expose source ${EXPECTED_SOURCE_SHA}..."
deadline=$((SECONDS + 1200))
last_status="not attempted"
while ((SECONDS < deadline)); do
  last_status=$(request \
    "${BASE_URL}/build-info.json" \
    "$workdir/build.headers" \
    "$workdir/build.json" || true)

  if [[ "$last_status" == "200" ]] &&
    jq -e --arg sha "$EXPECTED_SOURCE_SHA" '.source_sha == $sha' \
      "$workdir/build.json" >/dev/null 2>&1; then
    break
  fi

  sleep 15
done

if [[ "$last_status" != "200" ]] ||
  ! jq -e --arg sha "$EXPECTED_SOURCE_SHA" '.source_sha == $sha' \
    "$workdir/build.json" >/dev/null 2>&1; then
  echo "Timed out waiting for source ${EXPECTED_SOURCE_SHA}; last HTTP status was ${last_status}." >&2
  if [[ -s "$workdir/build.json" ]]; then
    jq -c . "$workdir/build.json" 2>/dev/null || head -c 500 "$workdir/build.json"
  fi
  exit 1
fi

build_cache=$(header_value "Cache-Control" "$workdir/build.headers")
build_cache_lower=$(printf "%s" "$build_cache" | tr "[:upper:]" "[:lower:]")
if [[ "$build_cache_lower" != *no-store* ]]; then
  echo "build-info.json must return Cache-Control containing no-store; got '${build_cache}'." >&2
  exit 1
fi

for asset in manifest.webmanifest service-worker.js offline-assets.json; do
  status=$(request \
    "${BASE_URL}/${asset}" \
    "$workdir/${asset}.headers" \
    "$workdir/${asset}.body")
  if [[ "$status" != "200" ]]; then
    echo "${asset} returned HTTP ${status}, expected 200." >&2
    exit 1
  fi

  cache_control=$(header_value "Cache-Control" "$workdir/${asset}.headers")
  cache_control_lower=$(printf "%s" "$cache_control" | tr "[:upper:]" "[:lower:]")
  if [[ "$cache_control_lower" != *no-cache* ]]; then
    echo "${asset} must return Cache-Control containing no-cache; got '${cache_control}'." >&2
    exit 1
  fi
done

jq -e 'type == "object" and (.name | type == "string")' \
  "$workdir/manifest.webmanifest.body" >/dev/null
jq -e . "$workdir/offline-assets.json.body" >/dev/null
test -s "$workdir/service-worker.js.body"

pmtiles_path=$(
  jq -r '.. | strings | select(test("\\.pmtiles([?#].*)?$"; "i"))' \
    "$workdir/offline-assets.json.body" |
    head -1
)
if [[ -z "$pmtiles_path" ]]; then
  echo "offline-assets.json does not contain a PMTiles asset." >&2
  exit 1
fi

pmtiles_url=$(
  python3 - "$BASE_URL" "$pmtiles_path" <<'PY'
import sys
from urllib.parse import urljoin, urlparse

base, path = sys.argv[1:]
url = urljoin(f"{base}/", path)
if urlparse(url).netloc != urlparse(base).netloc:
    raise SystemExit("PMTiles URL must remain on the protected vacations origin")
print(url)
PY
)

status=$(request \
  "$pmtiles_url" \
  "$workdir/range.headers" \
  "$workdir/range.body" \
  --header "Range: bytes=0-6")
if [[ "$status" != "206" ]] ||
  [[ "$(wc -c < "$workdir/range.body" | tr -d ' ')" != "7" ]] ||
  [[ "$(cat "$workdir/range.body")" != "PMTiles" ]]; then
  echo "PMTiles initial range must return HTTP 206 and the PMTiles magic bytes; got ${status}." >&2
  exit 1
fi

accept_ranges=$(header_value "Accept-Ranges" "$workdir/range.headers")
content_encoding=$(header_value "Content-Encoding" "$workdir/range.headers")
content_range=$(header_value "Content-Range" "$workdir/range.headers")
accept_ranges_lower=$(printf "%s" "$accept_ranges" | tr "[:upper:]" "[:lower:]")
content_encoding_lower=$(printf "%s" "$content_encoding" | tr "[:upper:]" "[:lower:]")
if [[ "$accept_ranges_lower" != "bytes" ]]; then
  echo "PMTiles response must advertise Accept-Ranges: bytes." >&2
  exit 1
fi
if [[ -n "$content_encoding" ]] && [[ "$content_encoding_lower" != "identity" ]]; then
  echo "PMTiles response must be uncompressed; got Content-Encoding: ${content_encoding}." >&2
  exit 1
fi
if [[ ! "$content_range" =~ ^bytes\ 0-6/([0-9]+)$ ]]; then
  echo "Invalid PMTiles Content-Range for initial request: ${content_range}." >&2
  exit 1
fi

total_size="${BASH_REMATCH[1]}"
if ((total_size < 7)); then
  echo "PMTiles asset is unexpectedly smaller than its header." >&2
  exit 1
fi

status=$(request \
  "$pmtiles_url" \
  "$workdir/suffix.headers" \
  "$workdir/suffix.body" \
  --header "Range: bytes=-2")
suffix_range=$(header_value "Content-Range" "$workdir/suffix.headers")
expected_start=$((total_size - 2))
expected_end=$((total_size - 1))
if [[ "$status" != "206" ]] ||
  [[ "$suffix_range" != "bytes ${expected_start}-${expected_end}/${total_size}" ]]; then
  echo "PMTiles suffix range was invalid: HTTP ${status}, Content-Range '${suffix_range}'." >&2
  exit 1
fi

status=$(request \
  "$pmtiles_url" \
  "$workdir/invalid.headers" \
  "$workdir/invalid.body" \
  --header "Range: bytes=${total_size}-")
invalid_range=$(header_value "Content-Range" "$workdir/invalid.headers")
if [[ "$status" != "416" ]] || [[ "$invalid_range" != "bytes */${total_size}" ]]; then
  echo "PMTiles invalid range must return HTTP 416 and the total size; got ${status}, '${invalid_range}'." >&2
  exit 1
fi

echo "Authenticated vacations smoke checks passed for ${EXPECTED_SOURCE_SHA}."

#!/bin/bash

# Usage: ./cleanup_unused_quality_profiles.sh [--dry-run]

DRY_RUN=false
[[ "$1" == "--dry-run" ]] && DRY_RUN=true

# Expected environment variables:
# RADARR_URL, RADARR_API_KEY
# SONARR_URL, SONARR_API_KEY

SERVICES=()

[[ -n "$RADARR_URL" && -n "$RADARR_API_KEY" ]] && SERVICES+=("Radarr|$RADARR_URL|$RADARR_API_KEY|movie")
[[ -n "$SONARR_URL" && -n "$SONARR_API_KEY" ]] && SERVICES+=("Sonarr|$SONARR_URL|$SONARR_API_KEY|series")

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "No services configured. Set RADARR_URL and/or SONARR_URL with corresponding *_API_KEY env vars."
  exit 1
fi

echo "Cleaning up unused quality profiles for the following services:"

for SERVICE in "${SERVICES[@]}"; do
  IFS='|' read -r NAME BASE_URL API_KEY TYPE <<< "$SERVICE"
  API_URL="$BASE_URL/api/v3"

  echo "=== $NAME ==="

  all_profiles=$(curl -s -H "X-Api-Key: $API_KEY" "$API_URL/qualityprofile")
  used_ids=$(curl -s -H "X-Api-Key: $API_KEY" "$API_URL/$TYPE" | jq '.[].qualityProfileId' | sort -u)

  echo "$all_profiles" | jq -c '.[]' | while read -r profile; do
    id=$(echo "$profile" | jq '.id')
    name=$(echo "$profile" | jq -r '.name')
    if ! echo "$used_ids" | grep -q "^$id$"; then
      echo "[Unused] $name (ID: $id)"
      if $DRY_RUN; then
        echo "  -> Would delete"
      else
        curl -s -X DELETE -H "X-Api-Key: $API_KEY" "$API_URL/qualityprofile/$id"
        echo "  -> Deleted"
      fi
    fi
  done

  echo "Done"
done


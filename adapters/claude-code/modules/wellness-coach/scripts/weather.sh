#!/bin/bash
set -euo pipefail
# Fetches current weather for a location
# Usage: weather.sh "City, Country"
# Output: JSON with temp_c, condition, is_outdoor_friendly
# Exits silently with empty output on failure

LOCATION="${1:-Oslo}"
TIMEOUT=5

# URL-encode the location
ENCODED_LOCATION=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$LOCATION" 2>/dev/null) || exit 0

# Fetch weather from wttr.in
WEATHER=$(curl -s --max-time "$TIMEOUT" "wttr.in/${ENCODED_LOCATION}?format=j1" 2>/dev/null) || true

if [ -z "$WEATHER" ]; then
  exit 0
fi

# Extract current condition
TEMP_C=$(echo "$WEATHER" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    current = data['current_condition'][0]
    temp = int(current['temp_C'])
    desc = current['weatherDesc'][0]['value']
    # Outdoor-unfriendly conditions
    bad_weather = ['Rain', 'Heavy rain', 'Snow', 'Thunderstorm', 'Blizzard', 'Freezing']
    is_outdoor = not any(bad in desc for bad in bad_weather)
    print(json.dumps({'temp_c': temp, 'condition': desc, 'is_outdoor_friendly': is_outdoor}))
except Exception:
    pass
" 2>/dev/null)

echo "$TEMP_C"

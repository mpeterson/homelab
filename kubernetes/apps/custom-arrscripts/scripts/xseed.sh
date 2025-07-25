#!/usr/bin/env bash
### UPDATED FOR SEASON PACK FROM USENET SUPPORT IN
### CROSS SEED v6 ONLY!! v5 IS NOT SUPPORTED FOR USENET
### SEASON PACKS AND WILL ALWAYS FAIL TO FIND MATCHES

### TO ENABLE THIS FEATURE YOU _MUST_ SWITCH TO THE
### ON IMPORT COMPLETE EVENT TYPE IN YOUR SONARR SETTINGS

### SEE FURTHER DOWN FOR CONFIGURATION SECTION, LEAVE THE HYPHEN (-) 
### IN FRONT OF THE CONFIGURATION OPTIONS AS SEEN IN THE EXAMPLES

# Load environment variables from .env file if it exists
# in the same directory as this bash script
VERSION='4.0.1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"
OLD_IFS="$IFS"

# Function to log messages
log_message() {
    local log_type="$1"
    local message="$2"
    local log_line
    log_line="$(date '+%Y-%m-%d %H:%M:%S') [$log_type] $message"
    if [ -f "$LOG_FILE" ]; then
        echo "$log_line" | tee -a "$LOG_FILE"
    else
        echo "$log_line"
    fi
}

log_message "INFO" "xseed.sh script started $VERSION"
EVAR=false
if [ -f "$ENV_PATH" ]; then
    # shellcheck source=.env
    log_message "INFO" "Loading environment variables from $ENV_PATH file"
    # shellcheck disable=SC1090 # shellcheck sucks
    if source "$ENV_PATH"; then
        log_message "INFO" "Environment variables loaded successfully"
        EVAR=true
    else
        log_message "ERROR" "Error loading environment variables" >&2
        exit 2
    fi
else
    log_message "DEBUG" ".env file not found in script directory ($ENV_PATH)"
fi

### START OF CONFIGURATION SECTION
### START OF CONFIGURATION SECTION

# Use environment variables with descriptive default values
# If you are not using environmental variables set your client
# in the ELSE section of the following if-else statement

if [[ -n "$TORRENT_CLIENTS" || -n "$USENET_CLIENTS" ]]; then
    # Convert from env to arrays
    IFS=','
    read -r -a TORRENT_CLIENTS <<<"$TORRENT_CLIENTS"
    read -r -a USENET_CLIENTS <<<"$USENET_CLIENTS"
else
    # If you are not using environmental variables set your client here
    # format for up to as many clients as you need
    # These must be exactly as they appear in the "Download Clients" section
    # of your respective arr client
    #
    # Multiple clients: (${TORRENT_CLIENTS:-"Qbit" "Qbit2"})
    # Single Client: (${TORRENT_CLIENTS:-"Qbit"})
    TORRENT_CLIENTS=("Qbit")
    USENET_CLIENTS=("SABnzbd")
fi

XSEED_HOST=${XSEED_HOST:-cross-seed}
XSEED_PORT=${XSEED_PORT:-2468}
XSEED_APIKEY=${XSEED_APIKEY:-abc123crossseedapikey}
LOG_FILE=${LOG_FILE:-/config/xseed.log}
LOGID_FILE=${LOGID_FILE:-/config/xseed-id.log}
### END OF CONFIGURATION SECTION

# Restore original IFS
IFS="$OLD_IFS"

log_message "DEBUG" "Using '.env' file for config?: $EVAR"
log_message "INFO" "Using Configuration:"
log_message "INFO" "TORRENT_CLIENTS=$(printf '"%s" ' "${TORRENT_CLIENTS[@]}")"
log_message "INFO" "USENET_CLIENTS=$(printf '"%s" ' "${USENET_CLIENTS[@]}")"
log_message "INFO" "XSEED_HOST=$XSEED_HOST"
log_message "INFO" "XSEED_PORT=$XSEED_PORT"
log_message "INFO" "LOG_FILE=$LOG_FILE"
log_message "INFO" "LOGID_FILE=$LOGID_FILE"

# Function to check if a client is in the allowed list
is_valid_client() {
    local client="$1"
    local client_type="$2"
    case $client_type in
    "torrent")
        for allowed_client in "${TORRENT_CLIENTS[@]}"; do
            if [[ "$client" == "$allowed_client" ]]; then
                return 0
            fi
        done
        ;;
    "usenet")
        for allowed_client in "${USENET_CLIENTS[@]}"; do
            if [[ "$client" == "$allowed_client" ]]; then
                return 0
            fi
        done
        ;;
    esac
    return 1
}

# Function to send a request to Cross Seed API
cross_seed_request() {
    local endpoint="$1"
    local data="$2"
    local headers=(-X POST "http://$XSEED_HOST:$XSEED_PORT/api/$endpoint" --data-urlencode "$data" --data-urlencode 'includeSingleEpisodes=true')
    if [ -n "$XSEED_APIKEY" ]; then
        headers+=(-H "X-Api-Key: $XSEED_APIKEY")
    fi
    response=$(curl --silent --output /dev/null --write-out "%{http_code}" "${headers[@]}")

    if [ "$response" == "000" ]; then
        log_message "ERROR" "Failed to connect to $XSEED_HOST:$XSEED_PORT. Timeout or connection refused."
    fi

    echo "$response"
}

# Detect application and set environment
detect_application() {
    app="unknown"
    if [ -n "$radarr_eventtype" ]; then
        app="radarr"
        # shellcheck disable=SC2154 # These are set by Starr on call
        clientID="$radarr_download_client"
        # shellcheck disable=SC2154 # These are set by Starr on call
        downloadID="$radarr_download_id"
        # shellcheck disable=SC2154 # These are set by Starr on call
        filePath="$radarr_moviefile_path"
        # shellcheck disable=SC2154 # These are set by Starr on call
        eventType="$radarr_eventtype"
    elif [ -n "$sonarr_eventtype" ]; then
        app="sonarr"
        # shellcheck disable=SC2154 # These are set by Starr on call
        sonarrReleaseType="$sonarr_release_releasetype"
        # shellcheck disable=SC2154 # These are set by Starr on call
        clientID="$sonarr_download_client"
        # shellcheck disable=SC2154 # These are set by Starr on call
        downloadID="$sonarr_download_id"
        if [ -n "$sonarrReleaseType" ] && [ "$sonarrReleaseType" == "SeasonPack" ]; then
            # shellcheck disable=SC2154 # These are set by Starr on call
            folderPath="$sonarr_destinationpath"
        else
            if [ -z "$sonarr_release_releasetype" ]; then
                # shellcheck disable=SC2154 # These are set by Starr on call
                folderPath="$sonarr_episodefile_sourcefolder"
                # shellcheck disable=SC2154 # These are set by Starr on call
                filePath="$sonarr_episodefile_path"
            else
                # shellcheck disable=SC2154 # These are set by Starr on call
                filePath="$sonarr_episodefile_paths"
            fi
        fi

        # shellcheck disable=SC2154 # These are set by Starr on call
        eventType="$sonarr_eventtype"
    fi
    if [ "$app" == "unknown" ]; then
        log_message "ERROR" "Unknown application type detected. Exiting."
        exit 2
    fi
    log_message "INFO" "Detected application: $app"
}

# Validate the process
validate_process() {
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"
    [ ! -f "$LOGID_FILE" ] && touch "$LOGID_FILE"
    unique_id="${downloadID}-${clientID}"

    if [ -z "$unique_id" ]; then
        log_message "ERROR" "Unique ID is missing. Exiting."
        exit 1
    fi

    if grep -qF "$unique_id" "$LOGID_FILE"; then
        log_message "INFO" "Download ID [$unique_id] already processed and logged in [$LOGID_FILE]. Exiting."
        exit 0
    fi

    if [ -z "$eventType" ]; then
        log_message "ERROR" "No event type specified. Exiting."
        exit 1
    fi

    if [ "$eventType" == "Test" ]; then
        log_message "INFO" "Test event detected. Exiting."
        exit 0
    fi

    if [ -z "$filePath" ] && [ -z "$folderPath" ] && [ -z "$downloadID" ]; then
        log_message "ERROR" "Essential parameters missing. Exiting."
        exit 2
    fi

    if [ -z "$downloadID" ]; then
        log_message "ERROR" "Download ID is missing. Checking if file path works for data/path based cross-seeding."
        if [[ -z "$filePath" && -z "$folderPath" ]]; then
            log_message "ERROR" "File and Folder paths are missing. Exiting."
            exit 2
        fi
    fi
}

# Function to send data for search
send_data_search() {
    if [ -n "$sonarrReleaseType" ] && [ "$sonarrReleaseType" == "SeasonPack" ]; then
        xseed_resp=$(cross_seed_request "webhook" "path=$folderPath")
    else
        xseed_resp=$(cross_seed_request "webhook" "path=$filePath")
    fi
}

# Main logic for handling operations
handle_operations() {
    detect_application
    validate_process
    # Check if client is a torrent client
    if is_valid_client "$clientID" "torrent"; then
        log_message "INFO" "Processing torrent client operations for $clientID..."
        if [ -n "$downloadID" ]; then
            xseed_resp=$(cross_seed_request "webhook" "infoHash=$downloadID")
        fi
        if [ "$xseed_resp" != "204" ]; then
            sleep 15
            send_data_search
        fi
    # Check if client is a usenet client
    elif is_valid_client "$clientID" "usenet"; then
        if [ -z "$sonarrReleaseType" ] && [[ "$folderPath" =~ S[0-9]{1,2}(?!\.E[0-9]{1,2}) ]]; then
            log_message "WARN" "Depreciated Action. Skipping season pack search. Please switch to On Import Complete for Usenet Season Pack Support!"
            exit 0
        fi
        log_message "INFO" "Processing Usenet client operations for $clientID..."
        send_data_search
    else
        log_message "ERROR" "Unrecognized client $clientID. Exiting."
        exit 2
    fi

    log_message "INFO" "Cross-seed API response: $xseed_resp"
    if [ "$xseed_resp" == "204" ]; then
        echo "$unique_id" >>"$LOGID_FILE"
        log_message "INFO" "Process completed successfully."
    else
        if [ "$xseed_resp" == "000" ]; then
            log_message "ERROR" "Process Timed Out. Exiting."
        fi
        log_message "ERROR" "Process failed with API response: $xseed_resp"
        exit 1
    fi
}

handle_operations

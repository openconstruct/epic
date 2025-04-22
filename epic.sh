#!/usr/bin/env bash

# --- Configuration ---
WALLPAPER_DIR="${HOME}/Pictures/SatelliteWallpaper"
# Base filename prefix
WALLPAPER_BASE_PREFIX="epic_earth"

# --- Script Logic ---
set -e # Exit immediately if a command exits with a non-zero status.
# set -u # Treat unset variables as an error. Commented out for DESKTOP_SESSION check.
set -o pipefail # Return value of a pipeline is the status of the last command to exit with a non-zero status

# --- Variables ---
# These will be set by fetch_epic_details
IMAGE_URL=""
IMAGE_FILENAME_COMPONENT="" # Unique part of the filename (e.g., API id)
IMAGE_EXTENSION="png"

# --- Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display error messages and exit
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Function to set wallpaper (same as before)
set_wallpaper() {
    local image_path="$1"
    local image_uri="file://${image_path}" # URI format needed by gsettings

    echo "Attempting to detect Desktop Environment to set wallpaper..."

    local desktop_env
    # Prefer XDG_CURRENT_DESKTOP
    if [[ -n "$XDG_CURRENT_DESKTOP" ]]; then
        desktop_env=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    # Fallback to DESKTOP_SESSION
    elif [[ -n "$DESKTOP_SESSION" ]]; then
        desktop_env=$(echo "$DESKTOP_SESSION" | tr '[:upper:]' '[:lower:]')
    else
        desktop_env="unknown"
    fi

    echo "Detected DE: ${desktop_env:-unknown}"

    if [[ "$desktop_env" =~ .*gnome.* || "$desktop_env" =~ .*cinnamon.* || "$desktop_env" =~ .*unity.* || "$desktop_env" == "ubuntu" ]]; then
        if command_exists gsettings; then
            echo "Using gsettings (GNOME/Cinnamon/Unity)..."
            # Try setting both standard and dark mode URIs
            gsettings set org.gnome.desktop.background picture-uri "$image_uri" || echo "Note: Failed to set org.gnome.desktop.background picture-uri"
            gsettings set org.gnome.desktop.background picture-uri-dark "$image_uri" || echo "Note: Failed to set org.gnome.desktop.background picture-uri-dark"
            # Attempt Cinnamon specific path as well
            if [[ "$desktop_env" =~ .*cinnamon.* ]]; then
                 gsettings set org.cinnamon.desktop.background picture-uri "$image_uri" || echo "Note: Failed to set org.cinnamon.desktop.background picture-uri"
            fi
            echo "Wallpaper potentially set using gsettings."
            return 0
        else
            echo "Warning: Detected GNOME/Cinnamon/Unity like DE but 'gsettings' command not found."
        fi
    elif [[ "$desktop_env" =~ .*mate.* ]]; then
         if command_exists gsettings; then
            echo "Using gsettings (MATE)..."
            gsettings set org.mate.background picture-filename "$image_path" || error_exit "gsettings command failed for MATE."
            echo "Wallpaper set using gsettings for MATE."
            return 0
         else
             echo "Warning: Detected MATE but 'gsettings' command not found."
         fi
    elif [[ "$desktop_env" =~ .*xfce.* || "$desktop_env" == "xfce" ]]; then
        if command_exists xfconf-query; then
            echo "Using xfconf-query (XFCE)..."
            # Find all properties related to the wallpaper image path across all screens/monitors
            props=$(xfconf-query -c xfce4-desktop -l | grep -E '/backdrop/screen.*/monitor.*/(image-path|last-image)') || true
            if [[ -n "$props" ]]; then
                echo "$props" | while read -r prop; do
                    echo "Setting XFCE property: $prop"
                    xfconf-query -c xfce4-desktop -p "$prop" -s "$image_path"
                done
                echo "Wallpaper set using xfconf-query for XFCE."
                return 0
            else
                echo "Warning: Could not find XFCE wallpaper properties via xfconf-query. Wallpaper might not be set."
            fi
        else
            echo "Warning: Detected XFCE but 'xfconf-query' command not found."
        fi
    elif [[ "$desktop_env" =~ .*kde.* || "$desktop_env" == "plasma" ]]; then
         # KDE Plasma uses D-Bus or kwriteconfig, D-Bus is often preferred
         if command_exists qdbus; then
             echo "Using D-Bus (KDE Plasma)..."
             # This command works for Plasma 5+
             # It iterates over all activities and desktops to set the wallpaper
             qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
                 var allDesktops = desktops();
                 for (var i=0; i<allDesktops.length; i++) {
                     var d = allDesktops[i];
                     d.wallpaperPlugin = 'org.kde.image';
                     d.currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
                     d.writeConfig('Image', 'file://${image_path}');
                 }" || echo "Warning: qdbus command for Plasma failed. Wallpaper might not be set."
            echo "Wallpaper potentially set using D-Bus for KDE Plasma."
            return 0
         else
             echo "Warning: Detected KDE/Plasma but 'qdbus' command not found. Cannot set wallpaper via D-Bus."
         fi
    fi


    # Fallback to feh
    if command_exists feh; then
        echo "Falling back to 'feh' to set wallpaper..."
        feh --bg-scale "$image_path"
        echo "Wallpaper set using 'feh --bg-scale'."
        echo "Note: For 'feh' persistence across reboots, add 'feh --bg-scale \"${image_path}\"' to your ~/.xsessionrc or equivalent startup script."
        return 0
    fi

    echo "Warning: Could not set wallpaper. No known method worked for your environment: ${desktop_env}."
    echo "You may need to set it manually: ${image_path}"
    echo "Consider installing 'feh' ('sudo apt install feh' or similar) for broader compatibility if other methods fail."
    return 1
}


# --- Source Specific Function (EPIC Only) ---

fetch_epic_details() {
    # Use the API endpoint that directly returns the latest natural image metadata
    local api_url="https://epic.gsfc.nasa.gov/api/natural"
    local archive_base_url="https://epic.gsfc.nasa.gov/archive/natural"

    echo "Fetching latest EPIC image data from NASA..."
    local api_response
    # Use -L to follow redirects, -f to fail on server errors, -s silent, -S show errors
    api_response=$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url") # Added timeouts
    local curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
       error_exit "Failed to fetch data from EPIC API: ${api_url} (curl exit code: $curl_exit_code)"
    fi
    if [[ -z "$api_response" ]]; then
        error_exit "EPIC API response was empty. Check API status or network connection: ${api_url}"
    fi

    # Validate JSON
    if ! echo "$api_response" | jq empty > /dev/null 2>&1; then
        error_exit "Invalid JSON received from EPIC API. URL was: ${api_url}. Response was: ${api_response}"
    fi

    # Parse the JSON to get the latest image details
    # This endpoint returns an array, usually with just the single latest image.
    # Use '.[0]' to safely get the first (and likely only) element.
    # Add check if array is empty or not an array first
    local latest_image_data
    latest_image_data=$(echo "$api_response" | jq 'if type=="array" and length > 0 then .[0] else null end')

    # Check if parsing was successful (jq returns null on failure or empty array)
    if [[ -z "$latest_image_data" || "$latest_image_data" == "null" ]]; then
        error_exit "Could not parse latest image data from EPIC API response. Response might be empty or not structured as expected: ${api_response}"
    fi

    local image_name date_str date_path
    # Extract fields from the single latest image object
    image_name=$(echo "$latest_image_data" | jq -r '.image')
    date_str=$(echo "$latest_image_data" | jq -r '.date') # Format: "YYYY-MM-DD HH:MM:SS"

    # Further validation on extracted fields
    if [[ -z "$image_name" || "$image_name" == "null" || "$image_name" == "" ]]; then
        error_exit "Could not extract valid image name from EPIC API response. Parsed object: ${latest_image_data}"
    fi
     if [[ -z "$date_str" || "$date_str" == "null" || "$date_str" == "" ]]; then
        error_exit "Could not extract valid date string from EPIC API response. Parsed object: ${latest_image_data}"
    fi

    # Construct the date path (YYYY/MM/DD) for the archive URL
    # Ensure date parsing is robust
    if ! date_path=$(echo "$date_str" | cut -d' ' -f1 | tr '-' '/'); then
         error_exit "Failed to parse date path from date string: ${date_str}"
    fi
    # Basic validation of date path format
    if ! [[ "$date_path" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]]; then
        error_exit "Parsed date path has unexpected format: ${date_path} (from date: ${date_str})"
    fi

    echo "Latest EPIC image found: ${image_name} from ${date_str}"

    # Set global variables needed for download/naming
    IMAGE_URL="${archive_base_url}/${date_path}/png/${image_name}.png"
    IMAGE_FILENAME_COMPONENT="${image_name}" # Use the unique image ID from NASA
    IMAGE_EXTENSION="png"
}

# --- Main Script ---

# Check core dependencies
echo "Checking dependencies..."
# Added gsettings and xfconf-query as optional checks here for clarity, but set_wallpaper handles missing commands
# mogrify comes from imagemagick usually
for cmd in curl jq wget mogrify; do
    command_exists "$cmd" || error_exit "'$cmd' command not found. Please install it (e.g., curl, jq, wget, imagemagick)."
done
echo "Core dependencies found."

# --- Argument Parsing ---
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <WIDTHxHEIGHT>"
    echo "Example: $0 1920x1080"
    exit 1
fi

TARGET_SIZE="$1" # Size is the first and only argument

# Validate size format
if ! [[ "$TARGET_SIZE" =~ ^[0-9]+x[0-9]+$ ]]; then
    error_exit "Invalid size format '$TARGET_SIZE'. Use WIDTHxHEIGHT (e.g., 1920x1080)."
fi
echo "Target wallpaper size: ${TARGET_SIZE}"

# Fetch image details (always EPIC now)
fetch_epic_details

# Create wallpaper directory if it doesn't exist
mkdir -p "$WALLPAPER_DIR" || error_exit "Could not create directory: ${WALLPAPER_DIR}"
echo "Wallpaper directory: ${WALLPAPER_DIR}"

# --- Download ---
# Construct the final path for the downloaded file
# Incorporate target size into the filename to keep different resolutions if needed
download_path="${WALLPAPER_DIR}/${WALLPAPER_BASE_PREFIX}_${IMAGE_FILENAME_COMPONENT}_${TARGET_SIZE}.${IMAGE_EXTENSION}"

# Define a common browser user agent
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"

echo "Image URL: ${IMAGE_URL}"
echo "Attempting to download to: ${download_path}"

# Use wget with user-agent, quiet mode (-q), output to file (-O), follow redirects (-L implicitly via -q?), timeout.
# Add --show-progress if not using -q for debugging, but -q is better for scripts
# Use --connect-timeout and --read-timeout
if ! wget --user-agent="$USER_AGENT" --connect-timeout=15 --read-timeout=60 -q -O "$download_path" "$IMAGE_URL"; then
    # Clean up partially downloaded file on error
    rm -f "$download_path"
    error_exit "Failed to download image using wget from: ${IMAGE_URL}"
fi
echo "Download appears complete."

# Check if download was successful (file exists and is not empty)
if [[ ! -s "$download_path" ]]; then
    # Clean up potentially empty file
    rm -f "$download_path"
    error_exit "Downloaded file is empty or download failed. Check URL or network connection. URL was: ${IMAGE_URL}"
fi
echo "Verified downloaded file exists and is not empty."

# --- Resize ---
echo "Resizing image to ${TARGET_SIZE} using mogrify..."
if ! mogrify -resize "$TARGET_SIZE" "$download_path"; then
    # Provide more context on failure
    file_type=$(file "$download_path")
    error_exit "Image resizing failed. Check ImageMagick installation and image file ('${download_path}'). File type reported: ${file_type}"
fi
echo "Image resized."

# --- Set Wallpaper ---
set_wallpaper "$download_path"

# --- Cleanup Old Wallpapers (Optional) ---
# Keep only the most recent N wallpapers to prevent disk space issues
# echo "Cleaning up old wallpapers..."
# N_KEEP=5 # Number of wallpapers to keep
# ls -t "${WALLPAPER_DIR}/${WALLPAPER_BASE_PREFIX}"*.png 2>/dev/null | # List by time, newest first
#   awk -v nkeep="$N_KEEP" 'NR > nkeep' | # Get files older than the Nth
#   xargs -r rm -- # Remove them (xargs -r doesn't run rm if input is empty)
# echo "Cleanup complete."


echo "----------------------------------------"
echo "EPIC satellite wallpaper updated successfully!"
echo "Source: NASA EPIC (via /api/natural)"
echo "Image URL: ${IMAGE_URL}"
echo "Wallpaper stored at: ${download_path}"
echo "----------------------------------------"

exit 0
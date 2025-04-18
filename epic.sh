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

    if [[ "$desktop_env" =~ .*gnome.* || "$desktop_env" =~ .*cinnamon.* ]]; then
        if command_exists gsettings; then
            echo "Using gsettings (GNOME/Cinnamon)..."
            gsettings set org.gnome.desktop.background picture-uri "$image_uri" || true # Background
            gsettings set org.gnome.desktop.background picture-uri-dark "$image_uri" || true # Background (dark mode)
            gsettings set org.cinnamon.desktop.background picture-uri "$image_uri" || true # Cinnamon specific path
            echo "Wallpaper set using gsettings."
            return 0
        else
            echo "Warning: Detected GNOME/Cinnamon but 'gsettings' command not found."
        fi
    elif [[ "$desktop_env" =~ .*mate.* ]]; then
         if command_exists gsettings; then
            echo "Using gsettings (MATE)..."
            gsettings set org.mate.background picture-filename "$image_path"
            echo "Wallpaper set using gsettings for MATE."
            return 0
         else
             echo "Warning: Detected MATE but 'gsettings' command not found."
         fi
    elif [[ "$desktop_env" =~ .*xfce.* || "$desktop_env" == "xfce" ]]; then
        if command_exists xfconf-query; then
            echo "Using xfconf-query (XFCE)..."
            props=$(xfconf-query -c xfce4-desktop -l | grep "/backdrop/screen.*/monitor.*/image-path\|/backdrop/screen.*/monitor.*/last-image") || true
            if [[ -n "$props" ]]; then
                echo "$props" | while read -r prop; do
                    echo "Setting property: $prop"
                    xfconf-query -c xfce4-desktop -p "$prop" -s "$image_path"
                done
                echo "Wallpaper set using xfconf-query."
                return 0
            else
                echo "Warning: Could not find XFCE wallpaper properties via xfconf-query."
            fi
        else
            echo "Warning: Detected XFCE but 'xfconf-query' command not found."
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

    echo "Warning: Could not set wallpaper. No known method worked for your environment."
    echo "You may need to set it manually: ${image_path}"
    echo "Consider installing 'feh' for broader compatibility."
    return 1
}

# --- Source Specific Function (EPIC Only) ---

fetch_epic_details() {
    local api_url="https://epic.gsfc.nasa.gov/api/natural/images"
    local archive_base_url="https://epic.gsfc.nasa.gov/archive/natural"

    echo "Fetching latest EPIC image data from NASA..."
    local api_response
    # Use -L to follow redirects, -f to fail on server errors, -s silent, -S show errors
    api_response=$(curl -fsSL "$api_url")
    local curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
       error_exit "Failed to fetch data from EPIC API: ${api_url} (curl exit code: $curl_exit_code)"
    fi
    if [[ -z "$api_response" ]]; then
        error_exit "EPIC API response was empty. Check API status or network connection."
    fi

    # Validate JSON
    if ! echo "$api_response" | jq empty > /dev/null 2>&1; then
        error_exit "Invalid JSON received from EPIC API. URL was: ${api_url}. Response was: ${api_response}"
    fi

    # Parse the JSON to get the latest image details
    local latest_image_data
    latest_image_data=$(echo "$api_response" | jq '.[-1]') # Get the last element

    if [[ -z "$latest_image_data" || "$latest_image_data" == "null" ]]; then
        error_exit "Could not parse latest image data from EPIC API response."
    fi

    local image_name date_str date_path
    image_name=$(echo "$latest_image_data" | jq -r '.image')
    date_str=$(echo "$latest_image_data" | jq -r '.date') # Format: "YYYY-MM-DD HH:MM:SS"

    if [[ -z "$image_name" || "$image_name" == "null" || -z "$date_str" || "$date_str" == "null" ]]; then
        error_exit "Could not extract image name or date from EPIC API response."
    fi

    date_path=$(echo "$date_str" | cut -d' ' -f1 | tr '-' '/') # YYYY/MM/DD
    echo "Latest EPIC image found: ${image_name} from ${date_str}"

    # Set global variables needed for download/naming
    IMAGE_URL="${archive_base_url}/${date_path}/png/${image_name}.png"
    IMAGE_FILENAME_COMPONENT="${image_name}" # Use the unique image ID from NASA
    IMAGE_EXTENSION="png"
}

# --- Main Script ---

# Check core dependencies
echo "Checking dependencies..."
for cmd in curl jq wget mogrify; do
    command_exists "$cmd" || error_exit "'$cmd' command not found. Please install it."
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
download_path="${WALLPAPER_DIR}/${WALLPAPER_BASE_PREFIX}_${IMAGE_FILENAME_COMPONENT}_${TARGET_SIZE}.${IMAGE_EXTENSION}"

# Define a common browser user agent (kept just in case, though less likely needed for NASA)
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"

echo "Downloading image from ${IMAGE_URL}"
echo "Saving to: ${download_path}"
# Add --user-agent and -L to wget
wget --user-agent="$USER_AGENT" -qL -O "$download_path" "$IMAGE_URL" || error_exit "Failed to download image from: ${IMAGE_URL}"
echo "Download complete."


# Check if download was successful (file exists and is not empty)
if [[ ! -s "$download_path" ]]; then
    rm -f "$download_path" # Clean up potentially empty file
    error_exit "Downloaded file is empty or download failed. Check URL or network connection."
fi

# --- Resize ---
echo "Resizing image to ${TARGET_SIZE} using mogrify..."
mogrify -resize "$TARGET_SIZE" "$download_path" || error_exit "Image resizing failed. Check ImageMagick installation and image file ('${download_path}')."
echo "Image resized."

# --- Set Wallpaper ---
set_wallpaper "$download_path"

echo "----------------------------------------"
echo "EPIC satellite wallpaper updated successfully!"
echo "Source: NASA EPIC"
echo "Image URL: ${IMAGE_URL}"
echo "Wallpaper stored at: ${download_path}"
echo "----------------------------------------"

exit 0
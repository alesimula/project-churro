# note <text>: something a feature expected in the image by name wasn't there (renamed or
# dropped by a newer image?), so an edit didn't happen. Printed where it happens and listed
# again at the end of the build (churro.sh; docs/09-version-support.md).
note() { echo "   NOTE: $*"; if [ -n "${CHURRO_NOTES:-}" ]; then echo "$*" >> "$CHURRO_NOTES"; fi; }

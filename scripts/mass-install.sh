#!/bin/bash
# Mass install all apps from ~/Temp

APPS_DIR="$HOME/Temp"

if [ ! -d "$APPS_DIR" ]; then
    echo "Error: Directory $APPS_DIR does not exist"
    exit 1
fi

echo "Scanning $APPS_DIR for apps to install..."
echo ""

count=0
for app in "$APPS_DIR"/*; do
    if [ -f "$app" ]; then
        appname=$(basename "$app")
        
        echo "Installing: $appname"
        app-manager --install "$app"
        ((count++))
    fi
done

echo ""
echo "Done! Installed $count app(s)."

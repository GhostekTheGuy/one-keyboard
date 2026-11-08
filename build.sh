#!/bin/zsh
# Buduje JednaKlawiatura.app do /Applications.
# Uwaga: podpis ad-hoc - po każdej przebudowie trzeba ponownie włączyć aplikację w Dostępności.
set -e
cd "$(dirname "$0")"
APP=/Applications/JednaKlawiatura.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp mac/Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 mac/main.swift -o "$APP/Contents/MacOS/JednaKlawiatura" -framework Cocoa
codesign --force --sign - --identifier pl.ghost.jednaklawiatura "$APP"
echo "zbudowano: $APP"

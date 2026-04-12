#!/bin/sh
printf '\033c\033]0;%s\a' DemoOlimpiadiParty
base_path="$(dirname "$(realpath "$0")")"
"$base_path/game_server.x86_64" "$@"

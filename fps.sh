#!/bin/sh
printf '\033c\033]0;%s\a' fps
base_path="$(dirname "$(realpath "$0")")"
"$base_path/fps.x86_64" "$@"

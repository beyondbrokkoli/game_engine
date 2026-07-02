#!/bin/bash
# Ensures we are running from the project root to protect Lua's package.path
cd "$(dirname "$0")" || exit
exec ./bin/boot.elf

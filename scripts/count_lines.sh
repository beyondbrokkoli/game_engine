#!/usr/bin/env bash

# 1. Define directories to ignore entirely
EXCLUDE_DIRS=("external" "vendor" "libs" ".git" "build")

# 2. Define specific files or patterns to ignore
EXCLUDE_FILES=("sqlite3.c" "glad.c" "autogen.lua" "*_test.c" "vulkan_headers.lua" "dkjson.lua")

# 3. Build directory pruning arguments safely
PRUNE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    if [ ${#PRUNE_ARGS[@]} -gt 0 ]; then
        PRUNE_ARGS+=("-o")
    fi
    PRUNE_ARGS+=("-name" "$dir")
done

# 4. Build file exclusion arguments
FILE_EXCLUDE_ARGS=()
for file in "${EXCLUDE_FILES[@]}"; do
    FILE_EXCLUDE_ARGS+=("!" "-name" "$file")
done

# 5. Execute the search safely using grouped logic
# If PRUNE_ARGS is empty, we completely bypass the prune step to avoid syntax errors
if [ ${#PRUNE_ARGS[@]} -gt 0 ]; then
    find . -type d \( "${PRUNE_ARGS[@]}" \) -prune -o \
        -type f \( -name "*.c" -o -name "*.lua" -o -name "*.glsl" \) \
        \( "${FILE_EXCLUDE_ARGS[@]}" \) \
        -exec wc -l {} + | sort -n
else
    find . -type f \( -name "*.c" -o -name "*.lua" -o -name "*.glsl" \) \
        \( "${FILE_EXCLUDE_ARGS[@]}" \) \
        -exec wc -l {} + | sort -n
fi

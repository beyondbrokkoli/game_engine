import re
import os

filepath = 'c/new_main.c'
with open(filepath, 'r') as f:
    content = f.read()

# 1. Inject the SIMD header exactly where it belongs
if '<immintrin.h>' not in content:
    content = content.replace(
        '#include <stdatomic.h>',
        '#include <stdatomic.h>\n#include <immintrin.h> // Hardware pause intrinsic'
    )

# 2. Transform the destructive spinlocks into yielding spinlocks
# Matches: while (TAS(variable));
# Replaces: while (TAS(variable)) { _mm_pause(); }
content = re.sub(
    r'while\s*\(\s*TAS\(([^)]+)\)\s*\)\s*;',
    r'while (TAS(\1)) { _mm_pause(); }',
    content
)

with open(filepath, 'w') as f:
    f.write(content)

print("[SUCCESS] SIMD _mm_pause() intrinsics injected. CPU pipelines secured.")

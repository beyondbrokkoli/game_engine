import re
import sys
import os

def perfectionist_refactor(filepath):
    if not os.path.exists(filepath):
        print(f"Error: Could not find {filepath}")
        return

    with open(filepath, 'r') as f:
        content = f.read()

    # 1. Elevate TRUNCATED tags to prominent FUNCTION architecture blocks
    def format_tag(match):
        func_name = match.group(1)
        return (f"// [FUNCTION: {func_name}]")

    # Matches variations like // [TRUNCATED: func_name]
    content = re.sub(r'//\s*\[TRUNCATED:\s*(.+?)\]', format_tag, content)

    # 2. Compress atomic_load_explicit for acquire semantics
    # Captures the variable inside the &(...) and replaces it with LOAD(...)
    content = re.sub(r'atomic_load_explicit\(&([^,]+),\s*memory_order_acquire\)', r'LOAD(\1)', content)

    # 3. Compress atomic_store_explicit for release semantics
    # Captures the variable and the value, replacing with STORE(..., ...)
    content = re.sub(r'atomic_store_explicit\(&([^,]+),\s*([^,]+),\s*memory_order_release\)', r'STORE(\1, \2)', content)

    # Write the beautifully formatted code back to the safe copy
    with open(filepath, 'w') as f:
        f.write(content)

    print(f"Successfully refactored {filepath}.")

if __name__ == "__main__":
    perfectionist_refactor('c/new_main.c')

import re
import os

def perfectionist_refactor_v2(filepath):
    if not os.path.exists(filepath):
        print(f"Error: Could not find {filepath}")
        return

    with open(filepath, 'r') as f:
        content = f.read()

    # 1. Nuke ALL existing LOAD and STORE macros (broken or otherwise)
    # This regex catches lines starting with #define LOAD( or #define STORE(
    content = re.sub(r'^[ \t]*#define[ \t]+(?:LOAD|STORE)\b.*$\n?', '', content, flags=re.MULTILINE)

    # 2. Hoist the REAL macros directly beneath the stdatomic include
    correct_macros = (
        "#include <stdatomic.h>\n"
        "#define LOAD(var) atomic_load_explicit(&(var), memory_order_acquire)\n"
        "#define STORE(var, val) atomic_store_explicit(&(var), (val), memory_order_release)\n"
    )
    # Replace the first instance of the include with the include + the macros
    if "#include <stdatomic.h>" in content:
        content = content.replace("#include <stdatomic.h>", correct_macros, 1)
    else:
        print("Warning: <stdatomic.h> not found. Ensure it is included in your file.")

    # 3. Elevate TRUNCATED tags to prominent FUNCTION architecture blocks
    def format_tag(match):
        func_name = match.group(1)
        return (f"// =============================================================================\n"
                f"// [FUNCTION: {func_name}]\n"
                f"// =============================================================================")

    content = re.sub(r'//\s*\[TRUNCATED:\s*(.+?)\]', format_tag, content)

    # 4. Compress atomic_load_explicit for acquire semantics
    content = re.sub(r'atomic_load_explicit\(&([^,]+),\s*memory_order_acquire\)', r'LOAD(\1)', content)

    # 5. Compress atomic_store_explicit for release semantics
    content = re.sub(r'atomic_store_explicit\(&([^,]+),\s*([^,]+),\s*memory_order_release\)', r'STORE(\1, \2)', content)

    # Write the beautifully formatted, strictly defined code back
    with open(filepath, 'w') as f:
        f.write(content)

    print(f"Successfully sanitized macros and refactored {filepath}.")

if __name__ == "__main__":
    perfectionist_refactor_v2('c/new_main.c')

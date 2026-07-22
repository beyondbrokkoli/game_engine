import os
import re

C_DIR = "c"
# Matches ONLY local includes: #include "module.h"
# Ignores system includes like #include <stdio.h>
INCLUDE_PATTERN = re.compile(r'#include\s+"([^"]+)"')

def scan_dependencies():
    graph = {}
    for root, _, files in os.walk(C_DIR):
        for file in files:
            if not (file.endswith(".c") or file.endswith(".h")):
                continue

            filepath = os.path.join(root, file)
            # For C, we use the full filename (e.g. 'main.c') because
            # .c and .h files often share the same base name.
            graph[file] = []

            with open(filepath, 'r', encoding='utf-8') as f:
                for line in f:
                    # Ignore commented-out includes
                    if line.lstrip().startswith("//"):
                        continue

                    matches = INCLUDE_PATTERN.findall(line)
                    for req in matches:
                        req_clean = os.path.basename(req)
                        graph[file].append(req_clean)
    return graph

def generate_dot(graph):
    dot = ["digraph WeaverEngineC {", "  node [shape=box, style=filled, fillcolor=lightblue];"]
    for node, edges in graph.items():
        if not edges:
            dot.append(f'  "{node}";')
        for edge in edges:
            dot.append(f'  "{node}" -> "{edge}";')

    dot.append("}")
    # The explicit + "\n" here solves the terminal pollution
    # when you cat the generated deps_c.dot file!
    return "\n".join(dot) + "\n"

if __name__ == "__main__":
    deps = scan_dependencies()
    dot_output = generate_dot(deps)

    with open("deps_c.dot", "w") as f:
        f.write(dot_output)

    print("Generated deps_c.dot.")
    print("Run: dot -Tsvg deps_c.dot -o deps_c.svg")

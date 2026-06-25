import os
import re
import sys

LUA_DIR = "lua"
# Regex to catch require("module"), require 'module', or require("module")
REQUIRE_PATTERN = re.compile(r"require\s*(?:\(\s*['\"]([^'\"]+)['\"]\s*\)|['\"]([^'\"]+)['\"])")

def scan_dependencies():
    graph = {}
    for root, _, files in os.walk(LUA_DIR):
        for file in files:
            if not file.endswith(".lua"): continue

            filepath = os.path.join(root, file)
            mod_name = file.replace(".lua", "")
            graph[mod_name] = []

            with open(filepath, 'r', encoding='utf-8') as f:
                for line in f:
                    # Ignore commented lines
                    if line.lstrip().startswith("--"): continue

                    matches = REQUIRE_PATTERN.findall(line)
                    for match in matches:
                        # Extract the captured group that matched
                        req = match[0] if match[0] else match[1]
                        # Strip directory paths if you use things like require("dir.module")
                        req_clean = req.split('.')[-1]
                        graph[mod_name].append(req_clean)
    return graph

def generate_dot(graph):
    dot = ["digraph WeaverEngine {", "  node [shape=box, style=filled, fillcolor=lightgray];"]
    for node, edges in graph.items():
        if not edges:
            dot.append(f'  "{node}";')
        for edge in edges:
            dot.append(f'  "{node}" -> "{edge}";')
    dot.append("}")
    return "\n".join(dot)

if __name__ == "__main__":
    deps = scan_dependencies()
    dot_output = generate_dot(deps)

    with open("deps.dot", "w") as f:
        f.write(dot_output)

    print("Generated deps.dot.")
    print("Run: dot -Tsvg deps.dot -o deps.svg")

import os
import re

# Track root-level entry points explicitly alongside the lua directory
ROOT_LUA_FILES = ["build.lua", "main.lua"]
LUA_DIR = "lua"

REQUIRE_PATTERN = re.compile(r"require\s*(?:\(\s*['\"]([^'\"]+)['\"]\s*\)|['\"]([^'\"]+)['\"])")

def parse_file(filepath, graph):
    mod_name = os.path.splitext(os.path.basename(filepath))[0]
    if mod_name not in graph:
        graph[mod_name] = []

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            if line.lstrip().startswith("--"):
                continue

            matches = REQUIRE_PATTERN.findall(line)
            for match in matches:
                req = match[0] if match[0] else match[1]
                req_clean = req.split('.')[-1]
                graph[mod_name].append(req_clean)

def scan_dependencies():
    graph = {}

    # 1. Scan root files
    for root_file in ROOT_LUA_FILES:
        if os.path.exists(root_file):
            parse_file(root_file, graph)

    # 2. Scan lua directory
    for root, _, files in os.walk(LUA_DIR):
        for file in files:
            if file.endswith(".lua"):
                filepath = os.path.join(root, file)
                parse_file(filepath, graph)

    return graph

def generate_dot(graph):
    dot = ["digraph WeaverEngine {", "  node [shape=box, style=filled, fillcolor=lightgray];"]
    for node, edges in graph.items():
        if not edges:
            dot.append(f'  "{node}";')
        for edge in edges:
            dot.append(f'  "{node}" -> "{edge}";')
    dot.append("}")
    return "\n".join(dot) + "\n"

if __name__ == "__main__":
    deps = scan_dependencies()
    dot_output = generate_dot(deps)

    with open("deps.dot", "w") as f:
        f.write(dot_output)

    print("Generated deps.dot.")

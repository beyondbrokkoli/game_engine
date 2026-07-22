import os
import re

GLSL_DIR = "glsl"
# Matches #include "shared.glsl"
INCLUDE_PATTERN = re.compile(r'#include\s+"([^"]+)"')

def scan_dependencies():
    graph = {}
    for root, _, files in os.walk(GLSL_DIR):
        for file in files:
            if not file.endswith((".glsl", ".vert", ".frag", ".comp")):
                continue

            filepath = os.path.join(root, file)
            graph[file] = []

            with open(filepath, 'r', encoding='utf-8') as f:
                for line in f:
                    if line.lstrip().startswith("//"):
                        continue

                    matches = INCLUDE_PATTERN.findall(line)
                    for req in matches:
                        req_clean = os.path.basename(req)
                        graph[file].append(req_clean)
    return graph

def generate_dot(graph):
    dot = ["digraph WeaverEngineGLSL {", "  node [shape=box, style=filled, fillcolor=lightgreen];"]
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

    with open("deps_glsl.dot", "w") as f:
        f.write(dot_output)

    print("Generated deps_glsl.dot.")
    print("Run: dot -Tsvg deps_glsl.dot -o deps_glsl.svg")

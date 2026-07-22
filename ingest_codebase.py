import os
import uuid
import fnmatch
import sys
import re
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct
from google import genai

# The SDK automatically checks os.environ["GEMINI_API_KEY"]
client = genai.Client()

# --- Configuration ---
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "weaver_stable"
GEMINI_DIMENSIONS = 768  # Native dimension size for text-embedding-004

TARGET_DIRS = ["c", "lua", "glsl", "scripts"]
ALLOWED_EXTENSIONS = {".c", ".h", ".lua", ".glsl", ".frag", ".vert"}
DOT_FILE = "deps.dot"

BLACKLIST = [
    "vulkan_headers.lua",
    "*.spv",
    "dkjson.lua",
    "*.dot",
    "*.py",
    "*.sh",
]

def validate_lua_invariants(module_name, source_code, expected_deps_from_dot):
    """
    Acts as a strict invariant check. The physical requires in the Lua file
    MUST perfectly match the declared edges in deps.dot.
    """
    # Extract physical 'require' statements from the Lua source
    # Matches: require("module") or require 'module'
    matches = re.findall(r'require\s*\(\s*["\']([^"\']+)["\']\s*\)|require\s+["\']([^"\']+)["\']', source_code)

    # Flatten the tuple results from the regex and clean them up
    actual_requires = set()
    for match in matches:
        req = match[0] if match[0] else match[1]
        # Ignore external standard libraries like 'ffi', 'math', 'bit' if you don't track them in the dot file
        if req not in ["ffi", "math", "bit", "os", "io", "string"]:
            actual_requires.add(req)

    expected_requires = set(expected_deps_from_dot)

    # Remove standard libraries from expected if they snuck into the DOT file
    expected_requires = {dep for dep in expected_requires if dep not in ["ffi", "math", "bit"]}

    if actual_requires != expected_requires:
        print(f"\n[FATAL INVARIANT] Architecture drift detected in '{module_name}.lua'")
        print(f" |- Expected (deps.dot): {expected_requires}")
        print(f" |- Actual (Lua source): {actual_requires}")
        print(f" |- Missing in code: {expected_requires - actual_requires}")
        print(f" |- Undocumented in DOT: {actual_requires - expected_requires}")
        print("\nHalting vector ingestion. Fix the architecture first.")
        sys.exit(1)

def is_blacklisted(filepath):
    filename = os.path.basename(filepath)
    for pattern in BLACKLIST:
        if fnmatch.fnmatch(filename, pattern) or fnmatch.fnmatch(filepath, pattern):
            return True
    return False

def parse_dependencies(dot_filepath):
    """Parses the Graphviz DOT file to build a dependency map."""
    deps_map = {}
    if not os.path.exists(dot_filepath):
        print(f"[-] Dependency graph '{dot_filepath}' not found. Skipping topology injection.")
        return deps_map

    with open(dot_filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # Matches: "module_a" -> "module_b";
    edges = re.findall(r'"([^"]+)"\s*->\s*"([^"]+)"', content)
    for source, target in edges:
        if source not in deps_map:
            deps_map[source] = []
        deps_map[source].append(target)

    return deps_map

def get_embedding(text):
    response = client.models.embed_content(
        model="text-embedding-004",
        contents=text,
        config=dict(
            task_type="RETRIEVAL_DOCUMENT",
            title="weaver_engine_source"
        )
    )
    return response.embeddings[0].values

def main():
    print("Connecting to Qdrant...")
    qdrant = QdrantClient(url=QDRANT_URL)

    if qdrant.collection_exists(collection_name=COLLECTION_NAME):
        print(f"Purging stale vectors from '{COLLECTION_NAME}'...")
        qdrant.delete_collection(collection_name=COLLECTION_NAME)

    qdrant.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=GEMINI_DIMENSIONS, distance=Distance.COSINE),
    )
    print(f"Created fresh Qdrant collection '{COLLECTION_NAME}'.\n")

    # Load architecture topology
    print("Parsing architecture topology...")
    topology = parse_dependencies(DOT_FILE)
    points = []

    print("Scanning directories for module ingestion...")
    for directory in TARGET_DIRS:
        if not os.path.exists(directory):
            continue

        for root, _, files in os.walk(directory):
            for file in files:
                ext = os.path.splitext(file)[1].lower()
                module_name = os.path.splitext(file)[0]

                if ext in ALLOWED_EXTENSIONS:
                    filepath = os.path.join(root, file)

                    if is_blacklisted(filepath):
                        print(f" [SKIP] Blacklisted: {filepath}")
                        continue

                    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                        source_code = f.read().strip()

                    if not source_code:
                        continue

                    # Construct the architecture-aware payload
                    dependencies = topology.get(module_name, [])
                    dep_string = ", ".join(dependencies) if dependencies else "None (Level 0 / Root)"

                    contextual_payload = (
                        f"MODULE: {filepath}\n"
                        f"DEPENDENCIES: {dep_string}\n"
                        f"SOURCE CODE:\n{source_code}"
                    )

                    print(f" [OK] Vectorizing Module: {filepath} (Deps: {len(dependencies)})")
                    vector = get_embedding(contextual_payload)

                    # 1 File = 1 Chunk. UUID is generated cleanly from the filepath.
                    point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, filepath))

                    points.append(PointStruct(
                        id=point_id,
                        vector=vector,
                        payload={
                            "file": filepath,
                            "dependencies": dependencies,
                            "content": source_code,  # Keep the raw code clean for the LLM output
                            "full_context": contextual_payload
                        }
                    ))

    if points:
        print(f"\nUpserting {len(points)} modules into Qdrant...")
        qdrant.upsert(
            collection_name=COLLECTION_NAME,
            points=points
        )
        print("Codebase successfully indexed and mapped!")
    else:
        print("No valid files found to index.")

if __name__ == "__main__":
    main()

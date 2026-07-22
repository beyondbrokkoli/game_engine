import os
import sys
import uuid
import fnmatch
import re
import requests

# --- EXECUTION MODE ---
# 0 = STRICT VALIDATION ONLY (Dry Run, No DB, No LLM)
# 1 = LOCAL LLM TEST RUN (Upserts to Qdrant via Nomic 10.0.0.2)
# 2 = GEMINI PROD RUN (Upserts to Qdrant via Google GenAI API)
RUN_MODE = 1

if RUN_MODE == 2:
    from google import genai
    client = genai.Client()
    print("[SYSTEM] Loaded Google GenAI SDK.")

if RUN_MODE in [1, 2]:
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Configuration ---
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "weaver_stable"
GEMINI_DIMENSIONS = 768 # Matches both Nomic and Gemini natively!

# Nomic Local Host Settings
LOCAL_EMBED_URL = "http://10.0.0.2:8081/v1/embeddings"
LOCAL_API_KEY = "TEST1234"

TARGET_DIRS = ["c", "lua", "glsl", "scripts"]
ALLOWED_EXTENSIONS = {".c", ".h", ".lua", ".glsl", ".frag", ".vert"}

DOT_FILE_LUA = "deps.dot"
DOT_FILE_C = "deps_c.dot"
DOT_FILE_GLSL = "deps_glsl.dot"

BLACKLIST = [
    "vulkan_headers.lua",
    "*.spv",
    "dkjson.lua",
    "*.dot",
    "*.py",
    "*.sh",
    "minify.lua",
    "manual_minify.lua",
]

def is_blacklisted(filepath):
    filename = os.path.basename(filepath)
    for pattern in BLACKLIST:
        if fnmatch.fnmatch(filename, pattern) or fnmatch.fnmatch(filepath, pattern):
            return True
    return False

def parse_dependencies(dot_filepath):
    deps_map = {}
    if not os.path.exists(dot_filepath):
        print(f"[-] Dependency graph '{dot_filepath}' not found. Skipping topology injection.")
        return deps_map

    with open(dot_filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    edges = re.findall(r'"([^"]+)"\s*->\s*"([^"]+)"', content)
    for source, target in edges:
        if source not in deps_map:
            deps_map[source] = []
        deps_map[source].append(target)

    return deps_map

def validate_lua_invariants(module_name, source_code, expected_deps_from_dot):
    matches = re.findall(r'require\s*\(\s*["\']([^"\']+)["\']\s*\)|require\s+["\']([^"\']+)["\']', source_code)

    actual_requires = set()
    for match in matches:
        req = match[0] if match[0] else match[1]
        if req not in ["ffi", "math", "bit", "os", "io", "string"]:
            actual_requires.add(req)

    expected_requires = set(expected_deps_from_dot)
    expected_requires = {dep for dep in expected_requires if dep not in ["ffi", "math", "bit"]}

    if actual_requires != expected_requires:
        print(f"\n[FATAL INVARIANT] Architecture drift detected in '{module_name}.lua'")
        print(f" |- Expected (deps.dot): {expected_requires}")
        print(f" |- Actual (Lua source):  {actual_requires}")
        print(f" |- Missing in code:     {expected_requires - actual_requires}")
        print(f" |- Undocumented in DOT: {actual_requires - expected_requires}")
        print("\nHalting script. Fix the architecture first.")
        sys.exit(1)

def validate_include_invariants(file_name, source_code, expected_deps_from_dot, domain="C"):
    matches = re.findall(r'#include\s+"([^"]+)"', source_code)

    actual_requires = set()
    for match in matches:
        actual_requires.add(os.path.basename(match))

    expected_requires = set(expected_deps_from_dot)

    if actual_requires != expected_requires:
        print(f"\n[FATAL INVARIANT] {domain} Architecture drift detected in '{file_name}'")
        print(f" |- Expected (deps_{domain.lower()}.dot): {expected_requires}")
        print(f" |- Actual ({domain} source):     {actual_requires}")
        print(f" |- Missing in code:       {expected_requires - actual_requires}")
        print(f" |- Undocumented in DOT:   {actual_requires - expected_requires}")
        print(f"\nHalting script. Fix the {domain} architecture first.")
        sys.exit(1)

def get_embedding(text):
    if RUN_MODE == 0:
        return []

    elif RUN_MODE == 1:
        # Route through Local Nomic llama-server
        headers = {
            "Authorization": f"Bearer {LOCAL_API_KEY}",
            "Content-Type": "application/json"
        }
        payload = {"input": text}
        response = requests.post(LOCAL_EMBED_URL, headers=headers, json=payload)
        response.raise_for_status()
        return response.json()['data'][0]['embedding']

    elif RUN_MODE == 2:
        # Route through Gemini API
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
    if RUN_MODE == 0:
        print("\n=== MODE 0: DRY RUN VALIDATION ONLY ===")
    elif RUN_MODE == 1:
        print("\n=== MODE 1: LOCAL NOMIC EMBEDDING RUN ===")
    elif RUN_MODE == 2:
        print("\n=== MODE 2: GEMINI API PRODUCTION RUN ===")

    if RUN_MODE in [1, 2]:
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

    print("Parsing architecture topologies...")
    topology_lua = parse_dependencies(DOT_FILE_LUA)
    topology_c = parse_dependencies(DOT_FILE_C)
    topology_glsl = parse_dependencies(DOT_FILE_GLSL)
    points = []

    print("Scanning directories for module ingestion...\n")
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

                    # --- INVARIANT ASSERTION & DEPENDENCY RESOLUTION ---
                    if ext == ".lua":
                        dependencies = topology_lua.get(module_name, [])
                        validate_lua_invariants(module_name, source_code, dependencies)
                        print(f" [VALIDATED] {module_name}.lua strict requires match deps.dot.")

                    elif ext in [".c", ".h"]:
                        dependencies = topology_c.get(file, [])
                        validate_include_invariants(file, source_code, dependencies, domain="C")
                        print(f" [VALIDATED] {file} strict includes match deps_c.dot.")

                    elif ext in [".glsl", ".frag", ".vert"]:
                        dependencies = topology_glsl.get(file, [])
                        validate_include_invariants(file, source_code, dependencies, domain="GLSL")
                        print(f" [VALIDATED] {file} strict includes match deps_glsl.dot.")

                    else:
                        dependencies = []

                    dep_string = ", ".join(dependencies) if dependencies else "None (Level 0 / Root)"

                    contextual_payload = (
                        f"MODULE: {filepath}\n"
                        f"DEPENDENCIES: {dep_string}\n"
                        f"SOURCE CODE:\n{source_code}"
                    )

                    if RUN_MODE == 0:
                        print(f" [DRY RUN] Would vectorize: {filepath} (Deps: {len(dependencies)})")
                    else:
                        print(f" [OK] Vectorizing Module: {filepath} (Deps: {len(dependencies)})")
                        vector = get_embedding(contextual_payload)

                        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, filepath))
                        points.append(PointStruct(
                            id=point_id,
                            vector=vector,
                            payload={
                                "file": filepath,
                                "dependencies": dependencies,
                                "content": source_code,
                                "full_context": contextual_payload
                            }
                        ))

    if RUN_MODE == 0:
        print("\n=== DRY RUN COMPLETE: All invariants passed! ===")
        print(f"Would have upserted {len(TARGET_DIRS)} directories worth of modules.")
    elif points:
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

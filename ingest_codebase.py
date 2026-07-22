import os
import sys
import uuid
import re
import requests

# --- EXECUTION MODE ---
# 0 = STRICT VALIDATION ONLY (Dry Run, No DB, No LLM)
# 1 = LOCAL LLM TEST RUN (Upserts to Qdrant via Nomic 10.0.0.2)
# 2 = GEMINI PROD RUN (Upserts to Qdrant via Google GenAI API)
RUN_MODE = 1

# --- QDRANT SAFETY CONTROLS ---
# Set to True ONLY when changing dimensions or wanting to wipe deleted files.
# Otherwise, deterministic UUIDs will natively overwrite modified files without purging!
FORCE_FULL_REBUILD = False

# Isolate latent spaces. Nomic and Gemini MUST NOT mix!
COLLECTION_NAMES = {
    1: "weaver_dev_nomic",
    2: "weaver_prod_gemini"
}
# Default to nomic safety if Mode 0 is used for some reason
COLLECTION_NAME = COLLECTION_NAMES.get(RUN_MODE, "weaver_dev_nomic")

if RUN_MODE == 2:
    from google import genai
    client = genai.Client()
    print("[SYSTEM] Loaded Google GenAI SDK.")

if RUN_MODE in [1, 2]:
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Configuration ---
QDRANT_URL = "http://localhost:6333"
GEMINI_DIMENSIONS = 768 # Matches both Nomic and Gemini natively!

LOCAL_EMBED_URL = "http://10.0.0.2:8081/v1/embeddings"
LOCAL_API_KEY = "TEST1234"

DOT_FILE_LUA = "deps.dot"
DOT_FILE_C = "deps_c.dot"
DOT_FILE_GLSL = "deps_glsl.dot"

# --- THE ABSOLUTE SOURCE OF TRUTH ---
INGESTION_MANIFEST = [
    "build.lua",
    # Add your heavily chunked files here as you refactor them!
]

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
        headers = {
            "Authorization": f"Bearer {LOCAL_API_KEY}",
            "Content-Type": "application/json"
        }
        payload = {"input": text}
        response = requests.post(LOCAL_EMBED_URL, headers=headers, json=payload)
        response.raise_for_status()
        return response.json()['data'][0]['embedding']

    elif RUN_MODE == 2:
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
        print(f"\n=== MODE 1: LOCAL NOMIC EMBEDDING RUN ({COLLECTION_NAME}) ===")
    elif RUN_MODE == 2:
        print(f"\n=== MODE 2: GEMINI API PRODUCTION RUN ({COLLECTION_NAME}) ===")

    if RUN_MODE in [1, 2]:
        print("Connecting to Qdrant...")
        qdrant = QdrantClient(url=QDRANT_URL)

        collection_exists = qdrant.collection_exists(collection_name=COLLECTION_NAME)

        if collection_exists and FORCE_FULL_REBUILD:
            print(f" [!] FORCE_FULL_REBUILD is ON. Purging '{COLLECTION_NAME}'...")
            qdrant.delete_collection(collection_name=COLLECTION_NAME)
            collection_exists = False

        if not collection_exists:
            print(f" [*] Creating fresh Qdrant collection '{COLLECTION_NAME}'...")
            qdrant.create_collection(
                collection_name=COLLECTION_NAME,
                vectors_config=VectorParams(size=GEMINI_DIMENSIONS, distance=Distance.COSINE),
            )
        else:
            print(f" [*] Database active. Overwriting existing UUIDs without purging.")

    print("Parsing architecture topologies...")
    topology_lua = parse_dependencies(DOT_FILE_LUA)
    topology_c = parse_dependencies(DOT_FILE_C)
    topology_glsl = parse_dependencies(DOT_FILE_GLSL)
    points = []

    print(f"Validating and vectorizing {len(INGESTION_MANIFEST)} manifested files...\n")

    for filepath in INGESTION_MANIFEST:
        if not os.path.exists(filepath):
            print(f" [WARNING] File missing from disk: {filepath}")
            continue

        filename = os.path.basename(filepath)
        module_name = os.path.splitext(filename)[0]
        ext = os.path.splitext(filename)[1].lower()

        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            source_code = f.read().strip()

        if not source_code:
            print(f" [SKIP] Empty file: {filepath}")
            continue

        # --- INVARIANT ASSERTION & DEPENDENCY RESOLUTION ---
        if ext == ".lua":
            dependencies = topology_lua.get(module_name, [])
            validate_lua_invariants(module_name, source_code, dependencies)
            print(f" [VALIDATED] {module_name}.lua strict requires match deps.dot.")

        elif ext in [".c", ".h"]:
            dependencies = topology_c.get(filename, [])
            validate_include_invariants(filename, source_code, dependencies, domain="C")
            print(f" [VALIDATED] {filename} strict includes match deps_c.dot.")

        elif ext in [".glsl", ".frag", ".vert"]:
            dependencies = topology_glsl.get(filename, [])
            validate_include_invariants(filename, source_code, dependencies, domain="GLSL")
            print(f" [VALIDATED] {filename} strict includes match deps_glsl.dot.")

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
        print(f"Would have upserted {len(INGESTION_MANIFEST)} manifested files.")
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

# ==============================================================================
# QDRANT SNAPSHOT CHEAT SHEET
# ==============================================================================
# When your DB hits a milestone, drop these commands into a Python shell:
#
# from qdrant_client import QdrantClient
# qdrant = QdrantClient(url="http://localhost:6333")
#
# 1. CREATE SNAPSHOT:
# qdrant.create_snapshot(collection_name="weaver_prod_gemini")
#
# 2. LIST SNAPSHOTS:
# print(qdrant.list_snapshots(collection_name="weaver_prod_gemini"))
#
# 3. RESTORE SNAPSHOT (Requires full physical path on the Qdrant host):
# qdrant.recover_snapshot(
#     collection_name="weaver_prod_gemini",
#     location="file:///qdrant/snapshots/weaver_prod_gemini/weaver_prod_gemini-2026-07-22-10-31-53.snapshot"
# ) [1]
# ==============================================================================

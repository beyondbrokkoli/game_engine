import os
import uuid
import fnmatch
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
ALLOWED_EXTENSIONS = {".c", ".h", ".lua", ".glsl", ".frag", ".vert", ".py", ".sh"}

# --- Blacklist ---
# Accepts exact filenames or wildcards
BLACKLIST = [
    "vulkan_headers.lua",
    "*.spv", # Ignore compiled shaders just in case
    "*.py",
    "*.md",
    "*.sh",
    "deps.dot",
    "dkjson.lua"
]

def is_blacklisted(filepath):
    """Checks if the file matches any pattern in the blacklist."""
    filename = os.path.basename(filepath)
    for pattern in BLACKLIST:
        if fnmatch.fnmatch(filename, pattern) or fnmatch.fnmatch(filepath, pattern):
            return True
    return False

def get_embedding(text):
    """Generates an embedding vector using Gemini."""
    response = client.models.embed_content(
        model="text-embedding-004",
        contents=text,
        config=dict(
            task_type="RETRIEVAL_DOCUMENT",
            title="weaver_engine_source"
        )
    )
    return response.embeddings[0].values

def chunk_file(filepath, chunk_size=60, overlap=15):
    """Chunks text by lines with an overlap to maintain context."""
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.read().split('\n')

    chunks = []
    # Using max(1, ...) to prevent step size 0 if overlap >= chunk_size
    step = max(1, chunk_size - overlap) 
    for i in range(0, len(lines), step):
        chunk_lines = lines[i:i + chunk_size]
        chunk_text = '\n'.join(chunk_lines).strip()
        if chunk_text:
            chunks.append(chunk_text)
    return chunks

def main():
    print("Connecting to Qdrant...")
    qdrant = QdrantClient(url=QDRANT_URL)

    # --- Wipe the slate clean for a fresh session ---
    if qdrant.collection_exists(collection_name=COLLECTION_NAME):
        print(f"Purging stale vectors from '{COLLECTION_NAME}'...")
        qdrant.delete_collection(collection_name=COLLECTION_NAME)

    qdrant.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=GEMINI_DIMENSIONS, distance=Distance.COSINE),
    )
    print(f"Created fresh Qdrant collection '{COLLECTION_NAME}'.")

    points = []

    print("Scanning directories...")
    for directory in TARGET_DIRS:
        if not os.path.exists(directory):
            continue

        for root, _, files in os.walk(directory):
            for file in files:
                ext = os.path.splitext(file)[1].lower()
                if ext in ALLOWED_EXTENSIONS:
                    filepath = os.path.join(root, file)

                    # Intercept blacklisted files before chunking
                    if is_blacklisted(filepath):
                        print(f"Ignored (Blacklisted): {filepath}")
                        continue

                    print(f"Processing: {filepath}")

                    chunks = chunk_file(filepath)
                    for idx, chunk in enumerate(chunks):
                        vector = get_embedding(chunk)

                        # Generate a deterministic UUID
                        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{filepath}_{idx}"))

                        points.append(PointStruct(
                            id=point_id,
                            vector=vector,
                            payload={
                                "file": filepath,
                                "chunk_index": idx,
                                "content": chunk
                            }
                        ))

    if points:
        print(f"\nUpserting {len(points)} chunks into Qdrant...")
        qdrant.upsert(
            collection_name=COLLECTION_NAME,
            points=points
        )
        print("Codebase successfully indexed!")
    else:
        print("No valid files found to index.")

if __name__ == "__main__":
    main()

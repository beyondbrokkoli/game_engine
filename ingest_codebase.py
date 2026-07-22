import os
import uuid
import requests
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Configuration ---
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "weaver_stable" # Change to 'weaver_borked' when indexing the refactor repo

# Nomic Embedding Server
EMBED_API_URL = "http://10.0.0.2:8081/v1/embeddings"
API_KEY = "TEST1234"
NOMIC_DIMENSIONS = 768

TARGET_DIRS = ["c", "lua", "glsl", "scripts"]
ALLOWED_EXTENSIONS = {".c", ".h", ".lua", ".glsl", ".frag", ".vert", ".py", ".sh"}

def get_embedding(text):
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "input": text,
        "model": "nomic-embed-text-v1-5"
    }
    response = requests.post(EMBED_API_URL, json=payload, headers=headers)
    response.raise_for_status()
    return response.json()["data"][0]["embedding"]

def chunk_file(filepath, chunk_size=60, overlap=15):
    """Chunks text by lines with an overlap to maintain context."""
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.read().split('\n')

    chunks = []
    for i in range(0, len(lines), chunk_size - overlap):
        chunk_lines = lines[i:i + chunk_size]
        chunk_text = '\n'.join(chunk_lines).strip()
        if chunk_text:
            chunks.append(chunk_text)
    return chunks

def main():
    print("Connecting to Qdrant...")
    client = QdrantClient(url=QDRANT_URL)

    # Initialize the collection if it doesn't exist
    if not client.collection_exists(collection_name=COLLECTION_NAME):
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=NOMIC_DIMENSIONS, distance=Distance.COSINE),
        )
        print(f"Created Qdrant collection '{COLLECTION_NAME}'.")

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
                    print(f"Processing: {filepath}")

                    chunks = chunk_file(filepath)
                    for idx, chunk in enumerate(chunks):
                        vector = get_embedding(chunk)

                        # Generate a deterministic UUID based on the filepath and chunk index
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
        print(f"Upserting {len(points)} chunks into Qdrant...")
        client.upsert(
            collection_name=COLLECTION_NAME,
            points=points
        )
        print("Codebase successfully indexed!")
    else:
        print("No valid files found.")

if __name__ == "__main__":
    main()

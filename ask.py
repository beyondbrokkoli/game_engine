import sys
import requests

# --- EXECUTION MODE ---
# 1 = LOCAL LLM RUN (Nomic @ 10.0.0.2:8081 + DeepSeek @ 10.0.0.2:8080)
# 2 = GEMINI PROD RUN (Google GenAI API)
RUN_MODE = 1

if RUN_MODE == 2:
    from google import genai
    client = genai.Client()

from qdrant_client import QdrantClient

# --- Configuration ---
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "weaver_stable"

# Local Server Endpoints
LOCAL_EMBED_URL = "http://10.0.0.2:8081/v1/embeddings"
LOCAL_LLM_URL = "http://10.0.0.2:8080/v1/chat/completions"
LOCAL_API_KEY = "TEST1234"

qdrant = QdrantClient(url=QDRANT_URL)

def get_query_vector(text):
    """Generates a query embedding vector matching the active backend."""
    if RUN_MODE == 1:
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
            config=dict(task_type="RETRIEVAL_QUERY")
        )
        return response.embeddings[0].values

def search_codebase(query, limit=3):
    """Queries Qdrant for relevant modules and formats dependency metadata."""
    query_vector = get_query_vector(query)
    results = qdrant.query_points(
        collection_name=COLLECTION_NAME,
        query=query_vector,
        limit=limit
    )

    contexts = []
    for point in results.points:
        payload = point.payload
        deps = payload.get('dependencies', [])
        deps_str = ", ".join(deps) if deps else "None (Level 0 / Root)"

        contexts.append(
            f"--- FILE: {payload['file']} ---\n"
            f"DEPENDENCIES: {deps_str}\n"
            f"CONTENT:\n{payload['content']}"
        )
    return "\n\n".join(contexts)

def ask_llm(query, context):
    """Sends the retrieved context and question to the active LLM generator."""
    system_prompt = (
        "You are an expert C/Lua engine developer. "
        "Use the provided code context to answer the user's question accurately and concisely."
    )
    user_prompt = f"RETRIEVED CODE CONTEXT:\n{context}\n\nUSER QUESTION:\n{query}"

    if RUN_MODE == 1:
        headers = {
            "Authorization": f"Bearer {LOCAL_API_KEY}",
            "Content-Type": "application/json"
        }
        payload = {
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            "temperature": 0.2,
            "max_tokens": 2048
        }
        response = requests.post(LOCAL_LLM_URL, headers=headers, json=payload)
        response.raise_for_status()
        return response.json()['choices'][0]['message']['content']

    elif RUN_MODE == 2:
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=user_prompt,
            config=dict(
                system_instruction=system_prompt,
                temperature=0.2
            )
        )
        return response.text

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python ask.py \"How does tenant mailbox synchronization work?\"")
        sys.exit(1)

    query = " ".join(sys.argv[1:])
    print(f"🔍 Searching vector database for: '{query}'...")
    context = search_codebase(query)

    if RUN_MODE == 1:
        print("🤖 Local DeepSeek is thinking...")
    else:
        print("🤖 Gemini is thinking...")

    response = ask_llm(query, context)

    print("\n" + "="*50)
    print(response)
    print("="*50)

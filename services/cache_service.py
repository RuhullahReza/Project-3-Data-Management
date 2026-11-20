import os
import json
import hashlib
import redis

from services.neo4j_service import execute_query, load_queries

cache = redis.Redis(
    host=os.getenv("KEYDB_HOST", "localhost"),
    port=int(os.getenv("KEYDB_PORT", 6379)),
    username=os.getenv("KEYDB_USER"),
    password=os.getenv("KEYDB_PASSWORD"),
    decode_responses=True
)

queries = load_queries()

# TTL configuration (seconds)
TTL_CONFIG = {
    1: 300,
    2: 60,
    3: 60,
    4: 300,
    5: 60,
    6: 120,
    7: 60,
    8: 300,
    9: 300,
    10: 60,
    11: 600,
    12: 300,
    13: 300
}



import time
import json
import hashlib

def execute_cached_query(query_id, params=None):

    total_start = time.perf_counter()

    params = params or {}

    query = queries["Read"][query_id]
    ttl = TTL_CONFIG.get(query_id, 60)

    # Generate unique cache key
    key_data = json.dumps({
        "query_id": query_id,
        "params": params
    }, sort_keys=True, default=str)

    query_hash = hashlib.sha256(
        key_data.encode()
    ).hexdigest()

    cache_key = f"neo4j:read:{query_hash}"

    # 1. Cache lookup
    start = time.perf_counter()
    cached_result = cache.get(cache_key)
    cache_get_time = (time.perf_counter() - start) * 1000

    if cached_result is not None:
        print(f"[CACHE HIT] Read {query_id}")

        # 2. Deserialize cached result
        start = time.perf_counter()
        result = json.loads(cached_result)
        deserialize_time = (time.perf_counter() - start) * 1000

        total_time = (time.perf_counter() - total_start) * 1000

        print(f"KeyDB GET: {cache_get_time:.3f} ms")
        print(f"Deserialization: {deserialize_time:.3f} ms")
        print(f"Total HIT Time: {total_time:.3f} ms")

        return result

    print(f"[CACHE MISS] Read {query_id}")

    # 3. Execute Neo4j query
    start = time.perf_counter()
    result = execute_query(query, params)
    neo4j_time = (time.perf_counter() - start) * 1000

    # 4. Serialize result
    start = time.perf_counter()
    serialized_result = json.dumps(result, default=str)
    serialization_time = (time.perf_counter() - start) * 1000

    # 5. Store result in KeyDB
    start = time.perf_counter()
    cache.set(cache_key, serialized_result, ex=ttl)
    cache_set_time = (time.perf_counter() - start) * 1000

    total_time = (time.perf_counter() - total_start) * 1000

    print(f"KeyDB GET: {cache_get_time:.3f} ms")
    print(f"Neo4j Execution: {neo4j_time:.3f} ms")
    print(f"Serialization: {serialization_time:.3f} ms")
    print(f"KeyDB SET: {cache_set_time:.3f} ms")
    print(f"Total MISS Time: {total_time:.3f} ms")

    return result

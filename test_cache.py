
import time
import json
import hashlib

from services.cache_service import cache, execute_cached_query


QUERY_ID = 3
PARAMS = {}


# Generate the same cache key used by cache_service.py
key_data = json.dumps({
    "query_id": QUERY_ID,
    "params": PARAMS
}, sort_keys=True, default=str)

query_hash = hashlib.sha256(
    key_data.encode()
).hexdigest()

cache_key = f"neo4j:read:{query_hash}"


# Clear existing cache to ensure CACHE MISS
cache.delete(cache_key)

print("=" * 50)
print(f"Testing Read Query {QUERY_ID}")
print("Existing cache cleared")
print("=" * 50)


# First execution: CACHE MISS
start = time.perf_counter()

result = execute_cached_query(
    query_id=QUERY_ID,
    params=PARAMS
)

end = time.perf_counter()

print("\nQuery Success (From Neo4j)")
print(result)
print(f"Total Query Time (MISS): {(end - start) * 1000:.3f} ms")


print("\n" + "=" * 50)


# Second execution: CACHE HIT
start = time.perf_counter()

result = execute_cached_query(
    query_id=QUERY_ID,
    params=PARAMS
)

end = time.perf_counter()

print("\nQuery Success (Cached)")
print(result)
print(f"Total Query Time (HIT): {(end - start) * 1000:.3f} ms")


print("\n" + "=" * 50)
print("CACHE PERFORMANCE SUMMARY")
print("=" * 50)

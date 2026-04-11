import json
import os
import time
import redis


REDIS_HOST = os.environ.get("REDIS_HOST", "redis.openfaas-fn.svc.cluster.local")


def handle(event, context):
    """I/O-bound function: performs Redis read/write operations."""
    params = json.loads(event.body)
    key = params.get("key", "default_key")

    # Connect to Redis (network operation)
    r = redis.Redis(host=REDIS_HOST, port=6379, db=0)

    # Read operation
    value = r.get(key)

    # Write operation (simulate update)
    r.set(f"result:{key}", json.dumps({
        "value": value.decode() if value else "null",
        "timestamp": time.time(),
    }))

    # Read back the result
    result = r.get(f"result:{key}")

    return {
        "statusCode": 200,
        "body": result.decode(),
        "headers": {"Content-Type": "application/json"},
    }

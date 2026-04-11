import json
import random
import time
from PIL import Image


def handle(event, context):
    """CPU-bound function: generates and resizes a random image using Lanczos resampling."""
    params = json.loads(event.body)
    width = params.get("width", 1920)
    height = params.get("height", 1080)

    # Generate a random image (simulates receiving an image from storage)
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    for i in range(width):
        for j in range(height):
            pixels[i, j] = (
                random.randint(0, 255),
                random.randint(0, 255),
                random.randint(0, 255),
            )

    # Resize using Lanczos (CPU-intensive high-quality downscaling)
    target_width = width // 2
    target_height = height // 2
    resized = img.resize((target_width, target_height), Image.LANCZOS)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "original": f"{width}x{height}",
            "resized": f"{target_width}x{target_height}",
            "timestamp": time.time(),
        }),
        "headers": {"Content-Type": "application/json"},
    }

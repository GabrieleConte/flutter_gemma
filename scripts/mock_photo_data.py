#!/usr/bin/env python3
"""
Mock photo data in graph_rag.db.

For each PHOTO entity in the database, this script:
1. Finds the corresponding image in the epistwin_images folder
2. Generates a description using ollama's qwen3-vl:8b vision model
3. Generates a 768-dim embedding of the description using embeddinggemma
4. Updates the entity's description and embedding columns in the database

Requirements:
  - ollama running locally with models: qwen3-vl:8b, embeddinggemma
  - pip install requests (stdlib sqlite3, struct, base64 are used too)
"""

import argparse
import base64
import json
import os
import sqlite3
import struct
import sys
import time
import requests

# ── Config ──────────────────────────────────────────────────────────────────
OLLAMA_BASE = "http://localhost:11434"
VISION_MODEL = "qwen3-vl:8b"
EMBED_MODEL = "embeddinggemma"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DB_PATH = os.path.join(PROJECT_ROOT, "knowledge_base", "graph_rag.db")
IMAGES_DIR = os.path.join(PROJECT_ROOT, "knowledge_base", "epistwin_images")

EMBED_DIM = 768  # embeddinggemma output dimension
VISION_PROMPT = (
    "Describe this image in detail. Focus on what is depicted, "
    "the setting, objects, people, colors, and any notable features. "
    "Keep your description concise but informative (2-4 sentences)."
)


def image_to_base64(path: str) -> str:
    """Read an image file and return its base64-encoded content."""
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")


def generate_description(image_path: str) -> str:
    """Use qwen3-vl:8b via ollama to describe an image."""
    b64 = image_to_base64(image_path)
    payload = {
        "model": VISION_MODEL,
        "prompt": VISION_PROMPT,
        "images": [b64],
        "stream": False,
    }
    resp = requests.post(f"{OLLAMA_BASE}/api/generate", json=payload, timeout=120)
    resp.raise_for_status()
    return resp.json()["response"].strip()


def generate_embedding(text: str) -> list[float]:
    """Use embeddinggemma via ollama to embed a text string."""
    payload = {
        "model": EMBED_MODEL,
        "input": text,
    }
    resp = requests.post(f"{OLLAMA_BASE}/api/embed", json=payload, timeout=60)
    resp.raise_for_status()
    embeddings = resp.json()["embeddings"][0]
    assert len(embeddings) == EMBED_DIM, (
        f"Expected {EMBED_DIM}-dim embedding, got {len(embeddings)}"
    )
    return embeddings


def embedding_to_blob(embedding: list[float]) -> bytes:
    """Pack a list of floats into a little-endian float32 blob for SQLite."""
    return struct.pack(f"<{len(embedding)}f", *embedding)


def remove_photo_relationships(conn: sqlite3.Connection) -> int:
    """Delete all PHOTO→PHOTO relationships and return the count of deleted rows."""
    cursor = conn.cursor()
    cursor.execute(
        "DELETE FROM relationships "
        "WHERE source_id LIKE 'photo_%' AND target_id LIKE 'photo_%'"
    )
    deleted = cursor.rowcount
    conn.commit()
    return deleted


def main():
    parser = argparse.ArgumentParser(
        description="Mock photo data in graph_rag.db using ollama vision + embedding models."
    )
    parser.add_argument(
        "--no-remove-relationships",
        action="store_true",
        default=False,
        help="Skip removal of PHOTO→PHOTO relationships (removed by default).",
    )
    parser.add_argument(
        "--remove-relationships-only",
        action="store_true",
        default=False,
        help="Only remove PHOTO→PHOTO relationships, skip image processing.",
    )
    args = parser.parse_args()

    # Verify paths
    if not os.path.exists(DB_PATH):
        print(f"ERROR: Database not found at {DB_PATH}")
        sys.exit(1)
    if not os.path.isdir(IMAGES_DIR):
        print(f"ERROR: Images directory not found at {IMAGES_DIR}")
        sys.exit(1)

    # Connect to DB
    conn = sqlite3.connect(DB_PATH)

    # Remove PHOTO→PHOTO relationships (unless opted out)
    if not args.no_remove_relationships:
        deleted = remove_photo_relationships(conn)
        print(f"Removed {deleted} PHOTO→PHOTO relationships\n")
    else:
        print("Skipping PHOTO→PHOTO relationship removal (--no-remove-relationships)\n")

    if args.remove_relationships_only:
        conn.close()
        print("Done (--remove-relationships-only).")
        return

    # Build a lookup: filename -> full path (case-insensitive matching)
    available_images = {}
    for fname in os.listdir(IMAGES_DIR):
        full = os.path.join(IMAGES_DIR, fname)
        if os.path.isfile(full):
            available_images[fname] = full

    cursor = conn.cursor()

    # Fetch all PHOTO entities
    cursor.execute("SELECT id, name FROM entities WHERE type = 'PHOTO'")
    photos = cursor.fetchall()
    print(f"Found {len(photos)} PHOTO entities in database")
    print(f"Found {len(available_images)} images in {IMAGES_DIR}\n")

    success = 0
    skipped = 0

    for entity_id, entity_name in photos:
        # Match entity name to image file
        image_path = available_images.get(entity_name)
        if image_path is None:
            print(f"  SKIP: No image file found for entity '{entity_name}' (id: {entity_id})")
            skipped += 1
            continue

        print(f"Processing: {entity_name}")

        # Step 1: Generate description
        try:
            print(f"  Generating description...")
            t0 = time.time()
            description = generate_description(image_path)
            dt = time.time() - t0
            print(f"  Description ({dt:.1f}s): {description[:100]}...")
        except Exception as e:
            print(f"  ERROR generating description: {e}")
            skipped += 1
            continue

        # Step 2: Generate embedding from description
        try:
            print(f"  Generating embedding...")
            t0 = time.time()
            embedding = generate_embedding(description)
            dt = time.time() - t0
            print(f"  Embedding generated ({dt:.1f}s): {EMBED_DIM} dimensions")
        except Exception as e:
            print(f"  ERROR generating embedding: {e}")
            skipped += 1
            continue

        # Step 3: Update database
        blob = embedding_to_blob(embedding)
        cursor.execute(
            "UPDATE entities SET description = ?, embedding = ? WHERE id = ?",
            (description, blob, entity_id),
        )
        conn.commit()
        success += 1
        print(f"  ✓ Updated in database\n")

    conn.close()
    print(f"\nDone! Updated: {success}, Skipped: {skipped}")


if __name__ == "__main__":
    main()

"""Load/save the inventory to data/stock.json."""

import json
import os

DEFAULT_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "stock.json")


def load(path=DEFAULT_PATH):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def save(items, path=DEFAULT_PATH):
    # TODO(dan): should probably write to a temp file first
    with open(path, "w") as f:
        json.dump(items, f, indent=2)

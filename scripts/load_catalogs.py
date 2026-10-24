"""Load the reviewed local download trials and the separate generated source."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.app.db import make_database
from backend.app.catalog.datasets import load_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=Path, default=ROOT / "local-data/catalog-trials")
    parser.add_argument("--synthetic-count", type=int, default=20000)
    args = parser.parse_args()
    paths = {
        "abo": args.trials / "general",
        "wands": args.trials / "general/wands_products.tsv",
        "open_beauty_facts": args.trials / "domain/openbeautyfacts.jsonl",
        "open_products_facts": args.trials / "domain/openproductsfacts.jsonl",
        "open_food_facts": args.trials / "domain/openfoodfacts-sample.jsonl",
        "uci_retail": args.trials / "seeds/uci-online-retail-ii-products.jsonl",
        "northwind": args.trials / "seeds/northwind-product-supplier-seed.json",
        "adventureworks": args.trials / "seeds/adventureworks",
        "synthetic": None,
    }
    missing = [source for source, path in paths.items() if path is not None and not path.exists()]
    if missing:
        sys.exit("Missing reviewed source files: " + ", ".join(missing) + ". Use the separate catalog bundle or follow docs/catalog-integration.md.")
    engine, factory = make_database()
    results = []
    try:
        for source, path in paths.items():
            started = time.monotonic()
            images = args.trials / "general/abo_images.csv.gz" if source == "abo" else None
            result = load_source(factory, source, path, images=images, count=args.synthetic_count)
            result["elapsed_seconds"] = round(time.monotonic() - started, 2)
            results.append(result)
            print(json.dumps(result), flush=True)
        output = ROOT / "local-data/catalog-load-results.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({"sources": results, "total_records": sum(row["row_count"] for row in results)}, indent=2) + "\n")
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()

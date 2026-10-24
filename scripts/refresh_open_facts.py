"""Download and audit complete Open Facts metadata exports; never modify the DB."""
import argparse
import json
from pathlib import Path
import sys

import httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.catalog.open_facts_refresh import EXPORTS, RefreshError, refresh_source, validate_acquisition


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=sorted(EXPORTS), action="append", help="Repeat to acquire both sources")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "local-data/open-facts-refresh")
    parser.add_argument("--minimum-records", type=int, default=1, help="Reject any source below this usable record count")
    parser.add_argument("--dry-run", action="store_true", help="Show the acquisition plan without network or disk writes")
    parser.add_argument("--verify", type=Path, help="Verify an existing acquisition directory without downloading")
    args = parser.parse_args(argv)
    if args.verify and (args.source or args.dry_run):
        parser.error("--verify cannot be combined with --source or --dry-run")
    try:
        if args.verify:
            print(json.dumps(validate_acquisition(args.verify)))
            return 0
        sources = list(dict.fromkeys(args.source or EXPORTS))
        if args.dry_run:
            print(json.dumps({"sources": [{"source_id": source, "url": EXPORTS[source]} for source in sources],
                              "output_dir": str(args.output_dir), "minimum_records": args.minimum_records,
                              "modifies_database": False, "food_facts_sample": "preserved"}))
            return 0
        for source in sources:
            result = refresh_source(source, args.output_dir, minimum_records=args.minimum_records)
            print(json.dumps(result), flush=True)
        return 0
    except (ValueError, OSError, httpx.HTTPError) as error:
        print(json.dumps({"error": {"code": getattr(error, "code", "refresh_failed"),
                                    "message": "Refresh failed; previous acquisitions and database snapshots were preserved",
                                    "error_type": type(error).__name__}}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

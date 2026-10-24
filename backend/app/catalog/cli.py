"""Operator CLI: approved complete feed snapshots only; never public user uploads."""
import argparse
from datetime import datetime
import json
import sys

from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError

from ..db import make_database
from .affiliates import AffiliateFeedError, parse_feed
from .service import CatalogError, import_snapshot, revoke_feed
from .registry import SOURCES


def timestamp(value):
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError()
        return date.timestamp()
    except (ValueError, OverflowError):
        raise argparse.ArgumentTypeError("Use an ISO timestamp with timezone, e.g. 2026-10-25T08:00:00Z") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    ingest = commands.add_parser("import", help="Replace one approved complete source/catalog snapshot")
    ingest.add_argument("--source", choices=["impact", "cj"], required=True)
    ingest.add_argument("--catalog-id", required=True)
    ingest.add_argument("--file", required=True)
    ingest.add_argument("--merchant-id")
    ingest.add_argument("--merchant-name")
    ingest.add_argument("--currency")
    ingest.add_argument("--approval-reference", required=True, help="Nonsecret reference to the merchant agreement approving display/search")
    ingest.add_argument("--source-observed-at", required=True, type=timestamp, help="When the provider generated/exported this snapshot, not the local import time")
    ingest.add_argument("--freshness-seconds", type=int, default=86400, help="60–86400; choose the lower limit required by the agreement")
    revoke = commands.add_parser("revoke", help="Disable a catalog and purge its merchant/product/offer rows")
    revoke.add_argument("--source", choices=sorted(SOURCES), required=True)
    revoke.add_argument("--catalog-id", required=True)
    args = parser.parse_args(argv)
    engine, factory = make_database()
    try:
        if args.command == "revoke":
            revoke_feed(factory, args.source, args.catalog_id)
            result = {"revoked": True, "source_id": args.source, "catalog_id": args.catalog_id}
        else:
            records = parse_feed(args.source, args.file, catalog_id=args.catalog_id,
                                 merchant_id=args.merchant_id, merchant_name=args.merchant_name, currency=args.currency)
            result = import_snapshot(factory, args.source, args.catalog_id, records,
                                     approval_reference=args.approval_reference, source_observed_at=args.source_observed_at,
                                     freshness_seconds=args.freshness_seconds)
        print(json.dumps(result))
        return 0
    except (CatalogError, AffiliateFeedError) as error:
        print(json.dumps({"error": {"code": error.code, "message": str(error)}}), file=sys.stderr)
        return 1
    except ValidationError:
        # Provider data may contain identifiers; don't echo raw rows to shell logs.
        print(json.dumps({"error": {"code": "invalid_record", "message": "A feed row does not match the normalized catalog contract"}}), file=sys.stderr)
        return 1
    except IntegrityError:
        print(json.dumps({"error": {"code": "concurrent_import", "message": "A concurrent import changed this catalog; retry the same snapshot"}}), file=sys.stderr)
        return 1
    finally:
        engine.dispose()


if __name__ == "__main__":
    sys.exit(main())

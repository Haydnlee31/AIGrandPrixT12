"""Small persistent exact-product watches for the private development relay.

Only explicit watches are stored. No saved-library content, account credentials,
or AI inference is involved. Checks run while this relay process is running.
"""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
import re
import sqlite3
import threading
import time
from typing import Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .amazon_catalog_identity import amazon_asin
from .live_prices import PRICE_FAILURE_MESSAGES, PRICE_FAILURE_REASONS
from urllib.parse import urlsplit


DEFAULT_STORE = Path(__file__).resolve().parents[2] / "local-data" / "live-price-watches.db"
CHECK_INTERVAL = 15 * 60
MAX_WATCHES = 100
MAX_OWNER_WATCHES = 50
MAX_HISTORY = 60
PRICE_BASIS = "item_excluding_shipping"


def canonical_product_url(value: str) -> str:
    asin = amazon_asin(value)
    if asin is None:
        raise ValueError("Use an exact Amazon product link containing its ASIN.")
    domain = (urlsplit(value).hostname or "").removeprefix("www.")
    return f"https://www.{domain}/dp/{asin}"


class PriceWatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)
    action: Literal["list", "save", "check", "delete"]
    owner_id: UUID
    watch_id: UUID | None = None
    product_url: str | None = Field(default=None, max_length=2048)
    title: str | None = Field(default=None, min_length=1, max_length=300)
    target_minor: int | None = Field(default=None, strict=True, gt=0, le=100_000_000_000)
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")

    @model_validator(mode="after")
    def validate_action(self):
        if self.action == "save":
            if self.product_url is None or self.title is None:
                raise ValueError("Saving a watch requires a product link and title.")
            self.product_url = canonical_product_url(self.product_url)
            if self.target_minor is not None and self.currency is None:
                raise ValueError("A target price requires its currency.")
        elif self.action in {"check", "delete"} and self.watch_id is None:
            raise ValueError("Select the product watch to check or delete.")
        return self


class PriceWatchError(ValueError):
    pass


class _Connection(sqlite3.Connection):
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()


class PriceTrackingService:
    def __init__(self, checker, path=DEFAULT_STORE, *, clock=time.time):
        self.checker = checker
        self.path = Path(path)
        self.clock = clock
        self.lock = threading.RLock()
        self._initialized = False
        self._capacity = asyncio.Semaphore(4)

    def _connect(self):
        # Merely creating the app or service never creates a database.
        self.path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.path, timeout=5, factory=_Connection)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        if not self._initialized:
            connection.executescript("""
                CREATE TABLE IF NOT EXISTS watches (
                    id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                    product_url TEXT NOT NULL, title TEXT NOT NULL,
                    target_minor INTEGER, currency TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    check_generation INTEGER NOT NULL DEFAULT 0,
                    last_result TEXT, last_checked_at REAL, last_success_at REAL,
                    price_drop_minor INTEGER, target_reached INTEGER,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    UNIQUE(owner_id, product_url)
                );
                CREATE TABLE IF NOT EXISTS price_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    watch_id TEXT NOT NULL REFERENCES watches(id) ON DELETE CASCADE,
                    price_minor INTEGER NOT NULL, currency TEXT NOT NULL,
                    basis TEXT NOT NULL, checked_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS price_history_watch ON price_history(watch_id,id);
            """)
            self._initialized = True
        return connection

    def _list(self, owner_id):
        if not self.path.exists():
            return {"watches": []}
        with self.lock, self._connect() as db:
            rows = db.execute("SELECT * FROM watches WHERE owner_id=? ORDER BY updated_at DESC,id", (owner_id,)).fetchall()
            items = []
            for row in rows:
                history = db.execute("SELECT price_minor,currency,basis,checked_at FROM price_history WHERE watch_id=? ORDER BY id", (row["id"],)).fetchall()
                items.append({"id": row["id"], "product_url": row["product_url"], "title": row["title"],
                    "target_minor": row["target_minor"], "currency": row["currency"],
                    "last_result": json.loads(row["last_result"]) if row["last_result"] else None,
                    "history": [dict(point) for point in history], "price_drop_minor": row["price_drop_minor"],
                    "target_reached": None if row["target_reached"] is None else bool(row["target_reached"]),
                    "last_checked_at": row["last_checked_at"], "last_success_at": row["last_success_at"]})
            return {"watches": items}

    async def dispatch(self, request: PriceWatchRequest):
        owner = str(request.owner_id)
        if request.action == "list":
            return self._list(owner)
        watch_id = str(request.watch_id) if request.watch_id else None
        with self.lock, self._connect() as db:
            if request.action == "save":
                existing = db.execute("SELECT * FROM watches WHERE owner_id=? AND " + ("id=?" if watch_id else "product_url=?"),
                                      (owner, watch_id or request.product_url)).fetchone()
                if watch_id and existing is None:
                    raise PriceWatchError("This product watch no longer exists.")
                if existing is not None:
                    if existing["product_url"] != request.product_url:
                        raise PriceWatchError("Create a new watch to track a different product.")
                    watch_id = existing["id"]
                    db.execute("UPDATE watches SET title=?,target_minor=?,currency=?,version=version+1,updated_at=?,price_drop_minor=NULL,target_reached=NULL WHERE id=?",
                               (request.title, request.target_minor, request.currency, self.clock(), watch_id))
                else:
                    if db.execute("SELECT COUNT(*) FROM watches").fetchone()[0] >= MAX_WATCHES or db.execute("SELECT COUNT(*) FROM watches WHERE owner_id=?", (owner,)).fetchone()[0] >= MAX_OWNER_WATCHES:
                        raise PriceWatchError("The price-watch limit has been reached. Remove a watch first.")
                    watch_id = str(uuid4())
                    now = self.clock()
                    db.execute("INSERT INTO watches(id,owner_id,product_url,title,target_minor,currency,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                               (watch_id, owner, request.product_url, request.title, request.target_minor, request.currency, now, now))
            elif request.action == "delete":
                db.execute("DELETE FROM watches WHERE id=? AND owner_id=?", (watch_id, owner))
            elif db.execute("SELECT 1 FROM watches WHERE id=? AND owner_id=?", (watch_id, owner)).fetchone() is None:
                raise PriceWatchError("This product watch no longer exists.")
        if request.action in {"save", "check"}:
            await self._check(watch_id, owner)
        return self._list(owner)

    def _failure(self, url, reason="unverified_price"):
        # A checker may be replaced by a third-party provider. Persist only our
        # finite reason vocabulary and static copy, never arbitrary provider
        # errors, response bodies or credentials echoed in a failure message.
        if not isinstance(reason, str) or reason not in PRICE_FAILURE_REASONS:
            reason = "unverified_price"
        return {"status": "unavailable", "product_url": url, "asin": amazon_asin(url),
            "marketplace": (urlsplit(url).hostname or "").removeprefix("www."),
            "price_minor": None, "currency": None, "reference_price_minor": None,
            "reference_label": None, "discount_percent": None, "checked_at": self.clock(),
            "basis": PRICE_BASIS, "failure_reason": reason, "message": PRICE_FAILURE_MESSAGES[reason]}

    def _validated_result(self, value, url):
        if not isinstance(value, dict):
            return self._failure(url)
        try:
            if canonical_product_url(value.get("product_url", "")) != url:
                return self._failure(url, "identity_mismatch")
            # The checker may provide an explicit failed attempt. Keep that
            # status while never returning an earlier successful price as current.
            if value.get("status") != "available":
                return self._failure(url, value.get("failure_reason"))
            price, currency = value.get("price_minor"), value.get("currency")
            if type(price) is not int or not 0 < price <= 100_000_000_000 or not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency) or value.get("basis") != PRICE_BASIS:
                return self._failure(url)
            # Persist the checker's bounded public-product evidence, never an
            # arbitrary object or source HTML returned by a replacement checker.
            result = {key: value.get(key) for key in self._failure(url)}
            result["product_url"] = url
            result["asin"] = amazon_asin(url)
            result["marketplace"] = (urlsplit(url).hostname or "").removeprefix("www.")
            result["checked_at"] = self.clock()
            result["failure_reason"] = None
            result["message"] = str(result.get("message") or "Current product price verified.")[:500]
            reference = result.get("reference_price_minor")
            if type(reference) is not int or not price < reference <= 100_000_000_000:
                result.update(reference_price_minor=None, reference_label=None, discount_percent=None)
            else:
                # A percentage only comes from this exact primary price and
                # its declared reference price, never coupons or target prices.
                result["discount_percent"] = (reference - price) * 100 // reference
                result["reference_label"] = str(result.get("reference_label") or "Reference price")[:100]
            json.dumps(result, allow_nan=False)
            return result
        except (ValueError, TypeError, AttributeError):
            return self._failure(url)

    async def _check(self, watch_id, owner_id=None):
        async with self._capacity:
            with self.lock, self._connect() as db:
                row = db.execute("SELECT * FROM watches WHERE id=?" + (" AND owner_id=?" if owner_id else ""),
                                 (watch_id, owner_id) if owner_id else (watch_id,)).fetchone()
                if row is None:
                    return
                generation = row["check_generation"] + 1
                version = row["version"]
                db.execute("UPDATE watches SET check_generation=? WHERE id=?", (generation, watch_id))
                url = row["product_url"]
            try:
                value = await asyncio.wait_for(self.checker(url), timeout=20)
                result = self._validated_result(value, url)
            except asyncio.CancelledError:
                raise
            except TimeoutError:
                result = self._failure(url, "timeout")
            except Exception:
                result = self._failure(url)
            with self.lock, self._connect() as db:
                current = db.execute("SELECT * FROM watches WHERE id=? AND version=? AND check_generation=?", (watch_id, version, generation)).fetchone()
                if current is None:
                    return  # Deleted, edited or superseded while its request ran.
                now, drop, reached = self.clock(), None, None
                success = result["status"] == "available"
                if success:
                    previous = db.execute("SELECT * FROM price_history WHERE watch_id=? ORDER BY id DESC LIMIT 1", (watch_id,)).fetchone()
                    if previous and previous["currency"] == result["currency"] and previous["basis"] == result["basis"]:
                        difference = previous["price_minor"] - result["price_minor"]
                        drop = difference if difference > 0 else None
                    if current["target_minor"] is not None and current["currency"] == result["currency"]:
                        reached = int(result["price_minor"] <= current["target_minor"])
                    db.execute("INSERT INTO price_history(watch_id,price_minor,currency,basis,checked_at) VALUES(?,?,?,?,?)",
                               (watch_id, result["price_minor"], result["currency"], result["basis"], now))
                    db.execute("DELETE FROM price_history WHERE watch_id=? AND id NOT IN (SELECT id FROM price_history WHERE watch_id=? ORDER BY id DESC LIMIT ?)", (watch_id, watch_id, MAX_HISTORY))
                db.execute("UPDATE watches SET last_result=?,last_checked_at=?,last_success_at=?,price_drop_minor=?,target_reached=? WHERE id=?",
                           (json.dumps(result), now, now if success else current["last_success_at"], drop, reached, watch_id))

    async def check_due(self):
        if not self.path.exists():
            return 0
        with self.lock, self._connect() as db:
            rows = db.execute("SELECT id FROM watches WHERE last_checked_at IS NULL OR last_checked_at<=? ORDER BY COALESCE(last_checked_at,0),id LIMIT 10",
                              (self.clock() - CHECK_INTERVAL,)).fetchall()
        await asyncio.gather(*(self._check(row["id"]) for row in rows))
        return len(rows)

    async def run(self):
        while True:
            try:
                # Drain bounded batches; at most MAX_WATCHES persisted watches.
                for _ in range((MAX_WATCHES + 9) // 10):
                    if await self.check_due() < 10:
                        break
            except asyncio.CancelledError:
                raise
            except (OSError, sqlite3.Error):
                pass  # A temporary storage failure must not stop the relay.
            # Reconsider due watches every minute; a watch added just after a
            # worker pass must not wait almost two full 15-minute intervals.
            await asyncio.sleep(min(60, CHECK_INTERVAL))

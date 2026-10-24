"""Real SQLite persistence with controlled exact-item price observations."""
import asyncio
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

from backend.app.price_routes import register_prices
from backend.app.price_tracking import (
    CHECK_INTERVAL, MAX_HISTORY, PRICE_BASIS, PriceTrackingService,
    PriceWatchError, PriceWatchRequest,
)


URL = "https://www.amazon.in/dp/B07FCLBWD9"


def observation(price=630000, currency="INR", **changes):
    value = {"status": "available", "product_url": URL, "asin": "B07FCLBWD9", "marketplace": "amazon.in",
        "price_minor": price, "currency": currency, "reference_price_minor": 1650000,
        "reference_label": "MRP", "discount_percent": 61, "checked_at": 123.0,
        "basis": PRICE_BASIS, "message": "Observed on the exact product page."}
    value.update(changes)
    return value


class Checker:
    def __init__(self, *values):
        self.values = list(values)
        self.calls = []

    async def __call__(self, url):
        self.calls.append(url)
        value = self.values.pop(0) if len(self.values) > 1 else self.values[0]
        if isinstance(value, Exception):
            raise value
        return value


def request(owner, action, **values):
    return PriceWatchRequest(owner_id=owner, action=action, **values)


def save(owner, **values):
    return request(owner, "save", product_url=URL, title="Invicta watch", **values)


def test_creation_is_lazy_and_empty_list_does_not_create_database(tmp_path):
    path = tmp_path / "data" / "watches.db"
    service = PriceTrackingService(Checker(observation()), path)
    assert not path.exists()
    assert asyncio.run(service.dispatch(request(uuid4(), "list"))) == {"watches": []}
    assert not path.exists()


def test_prices_persist_drop_target_and_discount_use_exact_currency_and_basis(tmp_path):
    async def scenario():
        owner = uuid4()
        clock = [100.0]
        service = PriceTrackingService(Checker(observation(700000), observation(630000)), tmp_path / "watch.db", clock=lambda: clock[0])
        first = (await service.dispatch(save(owner, target_minor=650000, currency="INR")))["watches"][0]
        assert first["target_reached"] is False and first["price_drop_minor"] is None
        clock[0] = 200.0
        second = (await service.dispatch(request(owner, "check", watch_id=first["id"])))["watches"][0]
        assert second["price_drop_minor"] == 70000 and second["target_reached"] is True
        assert second["last_result"]["discount_percent"] == 61
        assert second["last_result"]["reference_label"] == "MRP"
        assert second["last_checked_at"] == second["last_success_at"] == 200
        assert [p["price_minor"] for p in second["history"]] == [700000, 630000]
        restored = PriceTrackingService(Checker(observation()), tmp_path / "watch.db")
        assert (await restored.dispatch(request(owner, "list")))["watches"] == [second]
    asyncio.run(scenario())


def test_failed_attempt_preserves_history_but_never_shows_old_price_as_current(tmp_path):
    async def scenario():
        owner = uuid4()
        clock = [100.0]
        checker = Checker(observation(), observation(status="unavailable", price_minor=500000, message="Amazon blocked the request."))
        service = PriceTrackingService(checker, tmp_path / "watch.db", clock=lambda: clock[0])
        first = (await service.dispatch(save(owner, target_minor=650000, currency="INR")))["watches"][0]
        clock[0] = 250.0
        failed = (await service.dispatch(request(owner, "check", watch_id=first["id"])))["watches"][0]
        assert failed["last_result"]["status"] == "unavailable"
        assert failed["last_result"]["price_minor"] is None and failed["last_result"]["discount_percent"] is None
        assert failed["last_success_at"] == 100 and failed["last_checked_at"] == 250
        assert failed["history"] == first["history"]
        assert failed["target_reached"] is None and failed["price_drop_minor"] is None
    asyncio.run(scenario())


def test_changed_currency_cannot_create_drop_or_target_hit(tmp_path):
    async def scenario():
        owner = uuid4()
        service = PriceTrackingService(Checker(observation(700000), observation(1000, "USD")), tmp_path / "watch.db")
        first = (await service.dispatch(save(owner, target_minor=650000, currency="INR")))["watches"][0]
        result = (await service.dispatch(request(owner, "check", watch_id=first["id"])))["watches"][0]
        assert result["price_drop_minor"] is None and result["target_reached"] is None
        assert [p["currency"] for p in result["history"]] == ["INR", "USD"]
    asyncio.run(scenario())


@pytest.mark.parametrize("value", [
    observation(basis="delivered_including_shipping"), observation(product_url="https://www.amazon.in/dp/B08F7VZSMD"),
    observation(price_minor=-2), observation(price_minor=True), observation(currency="S$"), RuntimeError("failure"),
])
def test_invalid_or_failed_observation_never_enters_history(tmp_path, value):
    service = PriceTrackingService(Checker(value), tmp_path / "watch.db")
    result = asyncio.run(service.dispatch(save(uuid4())))["watches"][0]
    assert result["last_result"]["status"] == "unavailable"
    assert result["history"] == [] and result["last_success_at"] is None


def test_duplicate_save_updates_watch_and_owner_boundary_is_enforced(tmp_path):
    async def scenario():
        owner, other = uuid4(), uuid4()
        service = PriceTrackingService(Checker(observation()), tmp_path / "watch.db")
        first = (await service.dispatch(save(owner)))["watches"][0]
        updated = (await service.dispatch(save(owner, target_minor=600000, currency="INR")))["watches"]
        assert len(updated) == 1 and updated[0]["id"] == first["id"]
        assert (await service.dispatch(request(other, "list"))) == {"watches": []}
        assert (await service.dispatch(request(other, "delete", watch_id=first["id"]))) == {"watches": []}
        with pytest.raises(PriceWatchError):
            await service.dispatch(request(other, "check", watch_id=first["id"]))
        assert len((await service.dispatch(request(owner, "list")))["watches"]) == 1
        assert (await service.dispatch(request(owner, "delete", watch_id=first["id"]))) == {"watches": []}
    asyncio.run(scenario())


def test_delete_during_network_check_cannot_resurrect_product(tmp_path):
    async def scenario():
        owner = uuid4()
        started, release = asyncio.Event(), asyncio.Event()
        async def delayed(url):
            started.set()
            await release.wait()
            return observation()
        service = PriceTrackingService(delayed, tmp_path / "watch.db")
        saving = asyncio.create_task(service.dispatch(save(owner)))
        await started.wait()
        watch_id = (await service.dispatch(request(owner, "list")))["watches"][0]["id"]
        await service.dispatch(request(owner, "delete", watch_id=watch_id))
        release.set()
        assert await saving == {"watches": []}
    asyncio.run(scenario())


def test_edit_or_newer_check_wins_over_slow_older_check(tmp_path):
    async def scenario():
        owner = uuid4()
        started, release = asyncio.Event(), asyncio.Event()
        calls = [0]
        async def delayed(url):
            calls[0] += 1
            if calls[0] == 1:
                started.set()
                await release.wait()
                return observation(900000)
            return observation(630000)
        service = PriceTrackingService(delayed, tmp_path / "watch.db")
        saving = asyncio.create_task(service.dispatch(save(owner)))
        await started.wait()
        watch_id = (await service.dispatch(request(owner, "list")))["watches"][0]["id"]
        await service.dispatch(save(owner, watch_id=watch_id, target_minor=650000, currency="INR"))
        release.set()
        result = (await saving)["watches"][0]
        assert result["last_result"]["price_minor"] == 630000 and result["target_reached"] is True
        assert len(result["history"]) == 1
    asyncio.run(scenario())


def test_due_schedule_and_history_are_bounded(tmp_path):
    async def scenario():
        owner = uuid4()
        now = [100.0]
        checker = Checker(observation())
        service = PriceTrackingService(checker, tmp_path / "watch.db", clock=lambda: now[0])
        watch_id = (await service.dispatch(save(owner)))["watches"][0]["id"]
        assert await service.check_due() == 0
        now[0] += CHECK_INTERVAL
        assert await service.check_due() == 1
        for _ in range(MAX_HISTORY + 5):
            await service.dispatch(request(owner, "check", watch_id=watch_id))
        assert len((await service.dispatch(request(owner, "list")))["watches"][0]["history"]) == MAX_HISTORY
    asyncio.run(scenario())


@pytest.mark.parametrize("changes", [
    {"product_url": "https://example.com/dp/B07FCLBWD9"}, {"product_url": "https://amazon.in/s?k=watch"},
    {"product_url": "https://amazon.in.evil.example/dp/B07FCLBWD9"}, {"target_minor": 0, "currency": "INR"},
    {"target_minor": 630000}, {"target_minor": True, "currency": "INR"}, {"title": "x" * 301},
])
def test_input_boundaries(changes):
    data = dict(owner_id=uuid4(), action="save", product_url=URL, title="Watch")
    data.update(changes)
    with pytest.raises(ValidationError):
        PriceWatchRequest(**data)


def test_routes_use_injected_checker_and_lifecycle_closes_worker(tmp_path):
    app = FastAPI()
    checker = Checker(observation())
    path = tmp_path / "watch.db"
    register_prices(app, checker=checker, store_path=path)
    assert not path.exists()
    with TestClient(app) as client:
        assert not path.exists()
        assert client.post("/v1/price-check", json={"product_url": URL}).json()["price_minor"] == 630000
        owner = str(uuid4())
        saved = client.post("/v1/price-watch", json={"action": "save", "owner_id": owner, "product_url": URL, "title": "Watch"})
        assert saved.status_code == 200 and len(saved.json()["watches"]) == 1
        assert client.post("/v1/price-watch", json={"action": "list", "owner_id": "not-a-uuid"}).status_code == 422
    assert app.state.price_tracking_task is None


def test_background_runner_actually_rechecks_a_due_watch(tmp_path):
    async def scenario():
        owner = uuid4()
        now = [100.0]
        checked = asyncio.Event()
        calls = [0]
        async def checker(url):
            calls[0] += 1
            if calls[0] > 1:
                checked.set()
                return observation(600000)
            return observation(700000)
        service = PriceTrackingService(checker, tmp_path / "background.db", clock=lambda: now[0])
        await service.dispatch(save(owner, target_minor=650000, currency="INR"))
        now[0] += CHECK_INTERVAL
        worker = asyncio.create_task(service.run())
        try:
            await asyncio.wait_for(checked.wait(), timeout=1)
            watch = (await service.dispatch(request(owner, "list")))["watches"][0]
            assert len(watch["history"]) == 2 and watch["target_reached"] is True
            assert watch["price_drop_minor"] == 100000
        finally:
            worker.cancel()
            with pytest.raises(asyncio.CancelledError):
                await worker
    asyncio.run(scenario())

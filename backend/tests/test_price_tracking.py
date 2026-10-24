"""Invented approved-feed records exercise real tracking logic without network calls."""
import time
from uuid import uuid4

import pytest
from sqlalchemy import select

from backend.app.db import Watch
from backend.app.tracking import check_due
from backend.app.catalog.service import revoke_feed
from backend.tests.test_catalog_integration import api, record, import_records


def merchant_record(price=12000, **offer_fields):
    item = record(title="Invented coffee machine")
    item["variant_key"] = "coffee-black-230v"
    item["offer"].update(price_minor=price, currency="SGD", availability="in_stock", **offer_fields)
    return item


def publish(api, item, observed):
    return import_records(api.app.state.factory, [item], observed=observed)


def post(api, path, body=None, key=None):
    return api.post('/v1' + path, json=body, headers={"Idempotency-Key": key or uuid4().hex})


def watch(api, target=10000, key=None):
    result = post(api, "/watches/catalog", {"source_id": "impact", "record_id": "invented-sku", "target_minor": target}, key)
    assert result.status_code == 201, result.text
    return result.json()


def test_catalog_watch_history_threshold_and_idempotency(api):
    t = time.time() - 100
    publish(api, merchant_record(), t)
    first = watch(api, key="same-save")
    assert watch(api, key="same-save") == first
    assert first["data_mode"] == "approved_feed"
    assert first["catalog"]["merchant_name"] == "Invented Merchant"
    assert first["last_price_minor"] == 12000
    assert len(api.get('/v1/watches').json()["items"]) == 1
    assert api.get('/v1/notifications').json()["items"] == []
    path = f"/watches/{first['id']}"
    publish(api, merchant_record(9900, shipping_minor=400), t + 10)
    checked = post(api, path + '/check').json()
    assert checked['below'] is True
    post(api, path + '/check')
    alerts = api.get('/v1/notifications').json()['items']
    assert len(alerts) == 1 and 'SGD 99.00' in alerts[0]['message']
    history = api.get('/v1' + path + '/history?limit=1').json()
    assert history['next_offset'] == 1 and history['items'][0]['amount_minor'] == 9900
    assert history['items'][0]['offer_snapshot']['shipping_minor'] == 400
    assert api.get('/v1' + path + '/history?offset=1').json()['items'][0]['amount_minor'] == 12000
    publish(api, merchant_record(9800), t + 20)
    post(api, path + '/check')
    assert len(api.get('/v1/notifications').json()['items']) == 1
    publish(api, merchant_record(11000), t + 30)
    post(api, path + '/check')
    publish(api, merchant_record(9700), t + 40)
    post(api, path + '/check')
    assert len(api.get('/v1/notifications').json()['items']) == 2


def test_ownership_simulation_isolation_and_pause(api):
    t = time.time() - 100
    publish(api, merchant_record(), t)
    saved = watch(api)
    path = f"/v1/watches/{saved['id']}"
    other = {"Authorization": "Bearer sam-token", "Idempotency-Key": "other"}
    assert api.get(path + '/history', headers=other).status_code == 404
    assert api.post(path + '/check', headers=other).status_code == 404
    # Real-mode server disables simulation altogether.
    assert post(api, f"/watches/{saved['id']}/simulate", {'variant_id': saved['variant_id'], 'amount_minor': 1, 'currency': 'SGD'}).status_code == 404
    api.patch(path, json={"enabled": False}, headers={"Idempotency-Key": "pause"})
    publish(api, merchant_record(8000), t + 10)
    post(api, f"/watches/{saved['id']}/check")
    assert len(api.get(path + '/history').json()['items']) == 1
    assert api.get('/v1/notifications').json()['items'] == []


@pytest.mark.parametrize('change', ['expired', 'identity', 'currency', 'withdrawn', 'out_of_stock'])
def test_unusable_observations_do_not_create_sale_alerts(api, change):
    t = time.time() - 100
    publish(api, merchant_record(), t)
    saved = watch(api)
    item = merchant_record(7000)
    if change == 'identity': item['variant_key'] = 'different-machine'
    if change == 'currency': item['offer']['currency'] = 'USD'
    if change == 'out_of_stock': item['offer']['availability'] = 'out_of_stock'
    publish(api, item, t + 10)
    if change == 'withdrawn': revoke_feed(api.app.state.factory, 'impact', 'invented-feed')
    if change == 'expired':
        with api.app.state.factory.begin() as db:
            from backend.app.db import CatalogProduct
            product = db.scalar(select(CatalogProduct))
            product.record = {**product.record, 'offer': {**product.record['offer'], 'expires_at': t}}
    post(api, f"/watches/{saved['id']}/check")
    assert api.get('/v1/notifications').json()['items'] == []
    history = api.get(f"/v1/watches/{saved['id']}/history").json()['items']
    assert len(history) == (2 if change == 'out_of_stock' else 1)


def test_scheduled_checks_observe_new_feed_once_and_wait_for_fresh_data(api):
    t = time.time() - 100
    publish(api, merchant_record(), t)
    saved = watch(api)
    publish(api, merchant_record(9000), t + 10)
    with api.app.state.factory.begin() as db:
        db.get(Watch, saved['id']).next_check_at = 0
    assert check_due(api.app.state.factory) == 1
    assert check_due(api.app.state.factory) == 0
    assert len(api.get('/v1/notifications').json()['items']) == 1
    assert len(api.get(f"/v1/watches/{saved['id']}/history").json()['items']) == 2


def test_missing_variant_and_invalid_target_rejected(api):
    item = merchant_record()
    item['variant_key'] = None
    publish(api, item, time.time() - 1)
    assert post(api, '/watches/catalog', {'source_id': 'impact', 'record_id': 'invented-sku', 'target_minor': 9000}).status_code == 422
    for target in [True, 0, -1, 1.5]:
        assert post(api, '/watches/catalog', {'source_id': 'impact', 'record_id': 'invented-sku', 'target_minor': target}).status_code == 422


def test_demo_server_cannot_inject_simulated_prices_into_merchant_watch(tmp_path):
    from fastapi.testclient import TestClient
    from backend.app.main import create_app
    app = create_app(f"sqlite:///{tmp_path / 'demo.db'}", embedded_worker=False,
                     demo_mode=True, tokens={"alex-token": "alex"})
    with TestClient(app) as client:
        client.headers['Authorization'] = 'Bearer alex-token'
        publish(client, merchant_record(), time.time() - 1)
        saved = watch(client)
        response = post(client, f"/watches/{saved['id']}/simulate", {
            'variant_id': saved['variant_id'], 'amount_minor': 1, 'currency': 'SGD'})
        assert response.status_code == 409
        assert len(client.get(f"/v1/watches/{saved['id']}/history").json()['items']) == 1

.PHONY: setup run worker test smoke-http smoke-swift migrate contracts check-contracts fixtures extension handoff catalog-load catalog-bundle
setup:
	uv venv .venv
	uv pip install --python .venv/bin/python -r requirements.lock

run:
	.venv/bin/python scripts/run_local.py

worker:
	.venv/bin/python -m backend.app.worker

test:
	.venv/bin/python -m pytest -q
	node --check frontend/app.js
	node --test clients/javascript/test/*.test.js extension/tests/*.test.js frontend/test/*.test.mjs
	node --test experiments/chrome-sidepanel/tests/*.test.js
	$(MAKE) check-contracts

migrate:
	.venv/bin/alembic upgrade head

contracts:
	.venv/bin/python scripts/export_contracts.py

check-contracts:
	.venv/bin/python scripts/export_contracts.py --check

smoke-http:
	.venv/bin/python scripts/smoke_http.py

# Explicit opt-in: makes one paid request with the backend's configured key.
smoke-astra:
	.venv/bin/python scripts/smoke_astra.py

# Explicit opt-in: bounded paid validation with synthetic media and a temporary DB.
smoke-multimodal-live:
	.venv/bin/python scripts/validate_multimodal_live.py --env-file .env

smoke-multimodal-swift:
	sh clients/ios/Scripts/multimodal_smoke.sh

smoke-swift:
	sh clients/ios/Scripts/smoke.sh

fixtures:
	.venv/bin/python clients/ios/Scripts/export_fixtures.py

extension:
	.venv/bin/python scripts/package_handoff.py

handoff: contracts fixtures test
	.venv/bin/python scripts/package_handoff.py --all

catalog-load: migrate
	.venv/bin/python scripts/load_catalogs.py

catalog-bundle:
	.venv/bin/python scripts/package_catalogs.py

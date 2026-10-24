"""Authenticated by the relay middleware; no purchases are performed here."""
import asyncio
from contextlib import asynccontextmanager, suppress

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .price_tracking import DEFAULT_STORE, PriceTrackingService, PriceWatchRequest, PriceWatchError


class PriceCheckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    product_url: str = Field(min_length=1, max_length=2048)


def register_prices(app: FastAPI, *, checker=None, store_path=DEFAULT_STORE, background=True):
    if checker is None:
        from .live_prices import check_price
        checker = check_price
    service = PriceTrackingService(checker, path=store_path)
    app.state.price_tracking_service = service
    app.state.price_tracking_task = None

    @app.post("/v1/price-check")
    async def price_check(request: PriceCheckRequest):
        return JSONResponse(await checker(request.product_url), headers={"Cache-Control": "no-store"})

    @app.post("/v1/price-watch")
    async def price_watch(request: PriceWatchRequest):
        try:
            return JSONResponse(await service.dispatch(request), headers={"Cache-Control": "no-store"})
        except PriceWatchError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error

    previous_lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(application):
        async with previous_lifespan(application) as state:
            if background:
                app.state.price_tracking_task = asyncio.create_task(service.run())
            try:
                yield state
            finally:
                task = app.state.price_tracking_task
                if task is not None:
                    task.cancel()
                    with suppress(asyncio.CancelledError):
                        await task
                    app.state.price_tracking_task = None

    app.router.lifespan_context = lifespan

    return service

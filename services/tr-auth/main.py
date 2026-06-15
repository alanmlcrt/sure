"""
Trade Republic Auth + Portfolio Sidecar
----------------------------------------
Trade Republic has no public API. Two things cannot be done from the Rails app
directly, so they live here:

  1. The HTTP login flow is protected by an AWS WAF browser challenge that can
     only be solved with a real (headless) browser. We use Playwright to obtain
     the WAF token, then drive TR's login endpoints.

  2. Portfolio data is only available over a reverse-engineered WebSocket API.

This sidecar exposes a tiny JSON/HTTP API consumed by Sure's
`Provider::TradeRepublic`:

  POST /initiate  { phoneNumber, pin }   -> { processId }
  POST /complete  { processId, tan }     -> { sessionToken, refreshToken }
  POST /refresh   { refreshToken }       -> { sessionToken, refreshToken }
  POST /portfolio { sessionToken }       -> { cash: {...}, securities: {...} }

Keeping the WebSocket here means Sure stays dependency-free (no Ruby WS gem)
and only speaks plain HTTP.
"""

import asyncio
import base64
import hashlib
import json
import logging
import uuid
from decimal import Decimal
from typing import Optional

import httpx
import websockets
from fastapi import FastAPI, HTTPException
from playwright.async_api import async_playwright
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("tr-auth")

app = FastAPI()

TR_API = "https://api.traderepublic.com"
TR_APP = "https://app.traderepublic.com"
WS_URL = "wss://api.traderepublic.com/"
WS_VERSION = 31

# In-memory store: processId -> waf_token (cleared after /complete)
pending_sessions: dict[str, str] = {}


# ─── Helpers ──────────────────────────────────────────────────────────────────

def generate_device_info() -> str:
    device_id = hashlib.sha512(uuid.uuid4().bytes).hexdigest()
    return base64.b64encode(json.dumps({"stableDeviceId": device_id}).encode()).decode()


async def get_waf_token() -> Optional[str]:
    """Loads app.traderepublic.com in headless Chromium and retrieves the AWS WAF token."""
    log.info("Launching headless browser to obtain AWS WAF token...")
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-dev-shm-usage"])
        context = await browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
        )
        page = await context.new_page()
        await page.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', { get: () => undefined })"
        )

        try:
            await page.goto(TR_APP, wait_until="domcontentloaded", timeout=20000)
        except Exception:
            pass

        # The WAF challenge resolves asynchronously, so a single read often misses
        # it. Poll the JS API + cookie for up to ~20s before giving up.
        waf_token = None
        for _ in range(20):
            try:
                waf_token = await page.evaluate(
                    "window.AWSWafIntegration ? window.AWSWafIntegration.getToken() : null"
                )
            except Exception:
                waf_token = None

            if not waf_token:
                for cookie in await context.cookies():
                    if "aws-waf-token" in cookie.get("name", "").lower():
                        waf_token = cookie["value"]
                        break

            if waf_token:
                log.info("Got WAF token")
                break

            await page.wait_for_timeout(1000)

        await browser.close()

        if not waf_token:
            log.warning("Could not obtain AWS WAF token — request may fail with 403")
        return waf_token


def tr_headers(waf_token: Optional[str]) -> dict:
    headers = {
        "Accept": "*/*",
        "Accept-Language": "fr",
        "Cache-Control": "no-cache",
        "Content-Type": "application/json",
        "Pragma": "no-cache",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "x-tr-app-version": "13.40.5",
        "x-tr-device-info": generate_device_info(),
        "x-tr-platform": "web",
        "Origin": TR_APP,
        "Referer": TR_APP + "/",
    }
    if waf_token:
        headers["x-aws-waf-token"] = waf_token
    return headers


def normalise_phone(phone: str) -> str:
    phone = phone.strip()
    if phone.startswith("0"):
        phone = "+33" + phone[1:]
    return phone.replace(" ", "")


# ─── Auth endpoints ─────────────────────────────────────────────────────────────

class InitiateRequest(BaseModel):
    phoneNumber: str
    pin: str


class CompleteRequest(BaseModel):
    processId: str
    tan: str


class RefreshRequest(BaseModel):
    refreshToken: str


class PortfolioRequest(BaseModel):
    sessionToken: str


@app.post("/initiate")
async def initiate(req: InitiateRequest):
    waf_token = await get_waf_token()
    phone = normalise_phone(req.phoneNumber)
    log.info("Initiating TR auth for %s", phone)

    async with httpx.AsyncClient(timeout=15) as client:
        try:
            resp = await client.post(
                f"{TR_API}/api/v1/auth/web/login",
                json={"phoneNumber": phone, "pin": req.pin},
                headers=tr_headers(waf_token),
            )
            log.info("TR /login -> %d  body: %s", resp.status_code, resp.text[:300])
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise HTTPException(status_code=e.response.status_code,
                                detail=f"TR rejected request: {e.response.text[:200]}")

    data = resp.json()
    process_id = data.get("processId")
    if not process_id:
        raise HTTPException(status_code=502, detail=f"TR did not return processId: {data}")

    pending_sessions[process_id] = waf_token or ""
    return {"processId": process_id}


@app.post("/complete")
async def complete(req: CompleteRequest):
    # Fetch a fresh WAF token — the one from /initiate may have expired while
    # the user read and typed the 2FA code.
    waf_token = await get_waf_token()
    pending_sessions.pop(req.processId, None)

    async with httpx.AsyncClient(timeout=15) as client:
        try:
            resp = await client.post(
                f"{TR_API}/api/v1/auth/web/login/{req.processId}/{req.tan}",
                headers=tr_headers(waf_token),
            )
            log.info("TR /login/complete -> %d", resp.status_code)
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise HTTPException(status_code=e.response.status_code,
                                detail=f"TR rejected 2FA: {e.response.text[:200]}")

    session_token = _cookie(resp, "tr_session")
    if not session_token:
        raise HTTPException(status_code=502,
                            detail="No tr_session cookie in TR response. "
                                   "The 2FA code may be invalid or expired.")

    refresh_token = _cookie(resp, "tr_refresh")
    log.info("TR auth complete — session obtained (refresh token: %s)", "yes" if refresh_token else "no")
    return {"sessionToken": session_token, "refreshToken": refresh_token}


@app.post("/refresh")
async def refresh_session(req: RefreshRequest):
    log.info("Refreshing TR session via tr_refresh token")
    async with httpx.AsyncClient(timeout=15) as client:
        try:
            resp = await client.post(
                f"{TR_API}/api/v1/auth/web/refresh",
                cookies={"tr_refresh": req.refreshToken},
                headers={
                    "Accept": "*/*",
                    "Content-Type": "application/json",
                    "Origin": TR_APP,
                    "Referer": TR_APP + "/",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
                },
            )
            log.info("TR /refresh -> %d", resp.status_code)
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise HTTPException(status_code=401, detail=f"TR refresh failed: {e.response.text[:200]}")

    session_token = _cookie(resp, "tr_session")
    if not session_token:
        raise HTTPException(status_code=401, detail="SESSION_EXPIRED")

    refresh_token = _cookie(resp, "tr_refresh")
    return {"sessionToken": session_token, "refreshToken": refresh_token or req.refreshToken}


def _cookie(resp: httpx.Response, name: str) -> Optional[str]:
    value = resp.cookies.get(name)
    if value:
        return value
    for cookie_str in resp.headers.get_list("set-cookie"):
        for part in cookie_str.split(";"):
            part = part.strip()
            if part.lower().startswith(f"{name.lower()}="):
                return part[len(name) + 1:]
    return None


# ─── Portfolio (WebSocket) ──────────────────────────────────────────────────────

def _extract_sec_accounts(session_token: str) -> list[str]:
    """Securities sub-account numbers are encoded in the JWT payload."""
    try:
        parts = session_token.split(".")
        if len(parts) < 2:
            return []
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        sec = payload.get("act", {}).get("acc", {}).get("owner", {}).get("default", {}).get("sec", [])
        return [str(s) for s in sec] if isinstance(sec, list) else []
    except Exception as e:  # noqa: BLE001
        log.warning("Failed to extract sec accounts from JWT: %s", e)
        return []


def _parse_ws(message: str):
    """TR frames look like '<id> <code> <payload>'. Returns (id, code, payload)."""
    pieces = message.split(" ", 2)
    if len(pieces) < 2:
        return None, None, message
    try:
        sub_id = int(pieces[0])
    except ValueError:
        return None, None, message
    code = pieces[1]
    payload = pieces[2] if len(pieces) > 2 else ""
    return sub_id, code, payload


def _connect_message() -> str:
    payload = {
        "locale": "fr",
        "platformId": "webtrading",
        "platformVersion": "chrome - 125.0.0",
        "clientId": "app.traderepublic.com",
        "clientVersion": "3.151.3",
    }
    return f"connect {WS_VERSION} {json.dumps(payload)}"


def _to_decimal(value) -> Decimal:
    try:
        return Decimal(str(value))
    except Exception:  # noqa: BLE001
        return Decimal(0)


async def _fetch_portfolio(session_token: str) -> dict:
    sec_accounts = _extract_sec_accounts(session_token)
    log.info("TR sec accounts: %s", sec_accounts)

    cash_payload: Optional[dict] = None
    positions: dict[str, dict] = {}        # isin -> raw position
    ticker_prices: dict[str, Decimal] = {}  # isin -> last price
    sub_to_isin: dict[int, str] = {}
    portfolio_subs: set[int] = set()

    sub_counter = 1  # id 1 reserved for availableCash
    expected_portfolios = max(len(sec_accounts), 1)
    received_portfolios = 0
    expected_tickers = -1
    received_tickers = 0
    auth_expired = False

    async with websockets.connect(
        WS_URL,
        additional_headers={"Origin": TR_APP},
        open_timeout=20,
        close_timeout=5,
    ) as ws:
        await ws.send(_connect_message())

        while True:
            try:
                message = await asyncio.wait_for(ws.recv(), timeout=30)
            except asyncio.TimeoutError:
                log.warning("TR WS receive timeout")
                break

            if message.strip() == "connected":
                await ws.send(f'sub 1 {json.dumps({"type": "availableCash", "token": session_token})}')
                if sec_accounts:
                    for acc in sec_accounts:
                        sub_counter += 1
                        portfolio_subs.add(sub_counter)
                        await ws.send(f'sub {sub_counter} {json.dumps({"type": "compactPortfolio", "secAccNo": acc, "token": session_token})}')
                else:
                    sub_counter += 1
                    portfolio_subs.add(sub_counter)
                    await ws.send(f'sub {sub_counter} {json.dumps({"type": "compactPortfolio", "token": session_token})}')
                continue

            sub_id, code, payload = _parse_ws(message)
            if sub_id is None:
                continue

            if "AUTHENTICATION_ERROR" in (payload or ""):
                auth_expired = True
                break

            if sub_id == 1:
                try:
                    cash_payload = json.loads(payload)
                except Exception:  # noqa: BLE001
                    cash_payload = None

            elif sub_id in portfolio_subs:
                received_portfolios += 1
                try:
                    root = json.loads(payload)
                    pos_array = root if isinstance(root, list) else root.get("positions", [])
                    new_tickers = 0
                    for pos in pos_array:
                        isin = pos.get("instrumentId", "")
                        if not isin:
                            continue
                        positions[isin] = pos
                        sub_counter += 1
                        sub_to_isin[sub_counter] = isin
                        exchange_id = pos.get("exchangeId", "")
                        ticker_id = f"{isin}.{exchange_id}" if exchange_id else f"{isin}.TRX"
                        await ws.send(f'sub {sub_counter} {json.dumps({"type": "ticker", "id": ticker_id, "token": session_token})}')
                        new_tickers += 1
                    expected_tickers = (0 if expected_tickers < 0 else expected_tickers) + new_tickers
                except Exception as e:  # noqa: BLE001
                    log.error("Failed to parse compactPortfolio: %s", e)
                    if expected_tickers < 0:
                        expected_tickers = 0

            elif sub_id in sub_to_isin:
                received_tickers += 1
                try:
                    root = json.loads(payload)
                    price = root.get("last", {}).get("price")
                    if price is not None:
                        ticker_prices[sub_to_isin[sub_id]] = _to_decimal(price)
                except Exception:  # noqa: BLE001
                    pass

            cash_done = cash_payload is not None
            portfolios_done = received_portfolios >= expected_portfolios
            tickers_done = portfolios_done and expected_tickers >= 0 and received_tickers >= expected_tickers
            if cash_done and tickers_done:
                break

    if auth_expired:
        raise HTTPException(status_code=401, detail="SESSION_EXPIRED")

    return _build_portfolio(cash_payload, positions, ticker_prices)


def _build_portfolio(cash_payload, positions, ticker_prices) -> dict:
    # Cash
    cash_value = Decimal(0)
    if isinstance(cash_payload, list):
        for item in cash_payload:
            cash_value = _to_decimal(item.get("amount") or item.get("value") or 0)
            break
    elif isinstance(cash_payload, dict):
        cash_value = _to_decimal(cash_payload.get("amount") or cash_payload.get("value") or 0)

    # Securities
    out_positions = []
    total_value = Decimal(0)
    for isin, pos in positions.items():
        quantity = _to_decimal(pos.get("netSize", 0))
        if quantity <= 0:
            continue
        average_buy_in = _to_decimal(pos.get("averageBuyIn", 0))
        current_price = ticker_prices.get(isin, average_buy_in)
        total_value += current_price * quantity
        out_positions.append({
            "isin": isin,
            "name": None,
            "quantity": str(quantity),
            "averageBuyIn": str(average_buy_in),
            "currentPrice": str(current_price),
            "currency": "EUR",
        })

    return {
        "cash": {"balance": str(cash_value), "currency": "EUR"},
        "securities": {"value": str(total_value), "currency": "EUR", "positions": out_positions},
    }


@app.post("/portfolio")
async def portfolio(req: PortfolioRequest):
    try:
        return await asyncio.wait_for(_fetch_portfolio(req.sessionToken), timeout=60)
    except HTTPException:
        raise
    except asyncio.TimeoutError:
        raise HTTPException(status_code=504, detail="Timed out fetching Trade Republic portfolio")
    except Exception as e:  # noqa: BLE001
        log.error("Portfolio fetch failed: %s", e)
        raise HTTPException(status_code=502, detail=f"Failed to fetch portfolio: {e}")


@app.get("/health")
async def health():
    return {"status": "ok"}

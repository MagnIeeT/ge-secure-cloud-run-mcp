"""Private Cloud Run MCP Server with StreamableHTTP and Dual-Header OAuth 2.0.

Architecture:
- Cloud Run IAM (--no-allow-unauthenticated) validates the Google-managed OIDC
  token in `X-Serverless-Authorization` sent by Gemini Enterprise.
- This Starlette middleware validates the end-user's OAuth 2.0 access token in
  `Authorization: Bearer <access_token>` so tools execute with per-user identity.
"""

from contextvars import ContextVar
import datetime
import logging
import os
from typing import Any

from dotenv import load_dotenv
import httpx
from mcp.server.mcpserver import MCPServer
from starlette.applications import Starlette
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
import uvicorn

# Load local .env when running outside Cloud Run (no-op if .env is absent).
load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("private-vpc-mcp")

GOOGLE_TOKENINFO_URL = os.environ.get(
    "OAUTH_TOKENINFO_URL", "https://oauth2.googleapis.com/tokeninfo"
)
REQUIRE_OAUTH = os.environ.get("REQUIRE_OAUTH", "true").lower() == "true"
SERVICE_NAME = os.environ.get("SERVICE_NAME", "private-vpc-mcp")

# Holds authenticated caller metadata for the active request context.
current_auth_context: ContextVar[dict[str, Any]] = ContextVar(
    "current_auth_context", default={}
)

mcp = MCPServer(SERVICE_NAME)


@mcp.tool()
def whoami() -> dict[str, Any]:
  """Returns the authenticated OAuth 2.0 user identity and dual-header auth status."""
  auth_ctx = current_auth_context.get()
  return {
      "authenticated_email": auth_ctx.get("email", "unauthenticated"),
      "subject": auth_ctx.get("sub", "unknown"),
      "scopes": auth_ctx.get("scope", ""),
      "has_x_serverless_authorization": auth_ctx.get(
          "has_serverless_auth", False
      ),
      "oauth_enforced": REQUIRE_OAUTH,
      "service": SERVICE_NAME,
  }


@mcp.tool()
def get_private_vpc_record(record_id: str) -> dict[str, Any]:
  """Fetches a sample confidential record from the private Cloud Run MCP server.

  Args:
    record_id: Identifier of the internal record to look up (for example, 'REC-101').
  """
  auth_ctx = current_auth_context.get()
  return {
      "record_id": record_id,
      "status": "ACTIVE",
      "classification": "INTERNAL_VPC_ONLY",
      "accessed_by": auth_ctx.get("email", "unauthenticated"),
      "has_x_serverless_authorization": auth_ctx.get(
          "has_serverless_auth", False
      ),
      "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
      "message": (
          f"Successfully retrieved private Cloud Run record '{record_id}' "
          "through Gemini Enterprise Egress Agent Gateway."
      ),
  }


async def _verify_google_oauth_token(token: str) -> dict[str, Any] | None:
  """Validates an OAuth 2.0 access token against Google's tokeninfo endpoint."""
  async with httpx.AsyncClient(timeout=5.0) as client:
    resp = await client.get(
        GOOGLE_TOKENINFO_URL, params={"access_token": token}
    )
    if resp.status_code != 200:
      logger.warning(
          "OAuth token validation failed with status %d", resp.status_code
      )
      return None
    return resp.json()


class OAuth2ValidationMiddleware(BaseHTTPMiddleware):
  """Validates the end-user OAuth 2.0 Bearer token on incoming MCP requests."""

  async def dispatch(self, request: Request, call_next) -> Response:
    if request.url.path == "/health":
      return await call_next(request)

    has_serverless_auth = "x-serverless-authorization" in request.headers
    auth_header = request.headers.get("authorization", "")

    logger.info(
        "Incoming %s %s | has_auth_header=%s | has_x_serverless_auth=%s",
        request.method,
        request.url.path,
        bool(auth_header),
        has_serverless_auth,
    )

    token_info: dict[str, Any] = {
        "has_serverless_auth": has_serverless_auth,
    }

    if auth_header.lower().startswith("bearer "):
      raw_token = auth_header.split(" ", 1)[1].strip()
      verified = await _verify_google_oauth_token(raw_token)
      if verified is None and REQUIRE_OAUTH:
        return JSONResponse(
            {"error": "Invalid or expired OAuth 2.0 Bearer token."},
            status_code=401,
        )
      if verified:
        token_info.update(verified)
    elif REQUIRE_OAUTH:
      return JSONResponse(
          {"error": "Missing Authorization: Bearer <token> header."},
          status_code=401,
      )

    ctx_token = current_auth_context.set(token_info)
    try:
      return await call_next(request)
    finally:
      current_auth_context.reset(ctx_token)


async def health_check(request: Request) -> JSONResponse:
  """Health check endpoint for local smoke tests and container probes."""
  del request
  return JSONResponse(
      {"status": "ok", "service": SERVICE_NAME, "oauth_enforced": REQUIRE_OAUTH}
  )


def create_app() -> Starlette:
  """Creates the Starlette ASGI app with StreamableHTTP MCP and OAuth middleware."""
  app = mcp.streamable_http_app(stateless_http=True, host="0.0.0.0")
  app.add_middleware(OAuth2ValidationMiddleware)
  app.add_route("/health", health_check, methods=["GET"])
  return app


app = create_app()

if __name__ == "__main__":
  port = int(os.environ.get("PORT", "8080"))
  uvicorn.run(app, host="0.0.0.0", port=port)

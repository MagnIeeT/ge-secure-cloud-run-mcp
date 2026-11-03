"""Smoke-tests the local StreamableHTTP MCP server (/health, initialize, tools/list, tools/call)."""

import asyncio
import json
import os
import sys

from dotenv import load_dotenv
import httpx

load_dotenv()


async def main() -> int:
  base_url = os.environ.get("MCP_LOCAL_URL", "http://127.0.0.1:8080")
  bearer_token = os.environ.get("TEST_BEARER_TOKEN", "")

  headers = {
      "Accept": "application/json, text/event-stream",
      "Content-Type": "application/json",
  }
  if bearer_token:
    headers["Authorization"] = f"Bearer {bearer_token}"

  async with httpx.AsyncClient(timeout=10.0) as client:
    # 1. Health check
    health_resp = await client.get(f"{base_url}/health")
    health_resp.raise_for_status()
    print(f"[1/4] GET /health -> {health_resp.status_code}: {health_resp.json()}")

    # 2. MCP initialize
    init_payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "local-smoke-test", "version": "0.1.0"},
        },
    }
    init_resp = await client.post(
        f"{base_url}/mcp", headers=headers, json=init_payload
    )
    if init_resp.status_code == 401:
      print(
          "\n[!] Received 401 Unauthorized because REQUIRE_OAUTH=true and no "
          "valid TEST_BEARER_TOKEN was supplied.\n"
          "    Run locally with either:\n"
          "      REQUIRE_OAUTH=false python server.py\n"
          "    or pass a Google OAuth token:\n"
          "      TEST_BEARER_TOKEN=$(gcloud auth print-access-token) python scripts/test_local_mcp.py",
          file=sys.stderr,
      )
      return 1
    init_resp.raise_for_status()
    print(f"[2/4] POST /mcp (initialize) -> {init_resp.status_code}")

    # 3. MCP tools/list
    list_payload = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {},
    }
    list_resp = await client.post(
        f"{base_url}/mcp", headers=headers, json=list_payload
    )
    list_resp.raise_for_status()
    print(f"[3/4] POST /mcp (tools/list) -> {list_resp.status_code}")
    print(f"      Response: {list_resp.text.strip()[:240]}...")

    # 4. MCP tools/call (whoami & get_private_vpc_record)
    call_payload = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "get_private_vpc_record",
            "arguments": {"record_id": "REC-101"},
        },
    }
    call_resp = await client.post(
        f"{base_url}/mcp", headers=headers, json=call_payload
    )
    call_resp.raise_for_status()
    print(f"[4/4] POST /mcp (tools/call get_private_vpc_record) -> {call_resp.status_code}")
    try:
      print(json.dumps(call_resp.json(), indent=2))
    except ValueError:
      print(call_resp.text.strip())

  print("\nAll local MCP smoke tests passed!")
  return 0


if __name__ == "__main__":
  raise SystemExit(asyncio.run(main()))

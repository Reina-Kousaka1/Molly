#!/usr/bin/env python3
"""Run the Luvit Ollama/Discord E2E against an ephemeral loopback-only mock."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_PROMPTS = [
    "say hello",
    "simulate header timeout",
    "simulate body timeout",
    "simulate provider error",
    "recover please",
]


class State:
    def __init__(self) -> None:
        self.requests: list[dict[str, object]] = []
        self.problems: list[str] = []
        self.lock = threading.Lock()


def handler_for(state: State):
    class MockHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, _format: str, *_args: object) -> None:
            # Never print prompt bodies or test request data.
            return

        def respond(self, status: int, payload: dict[str, object]) -> None:
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                # Expected when the client correctly times out before the late mock reply.
                pass

        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if self.path != "/api/chat":
                with state.lock:
                    state.problems.append("unexpected_path")
                self.respond(404, {"error": "unexpected mock path"})
                return

            try:
                length = int(self.headers.get("Content-Length", "-1"))
                if length < 0 or length > 65536:
                    raise ValueError("invalid_length")
                request = json.loads(self.rfile.read(length))
                messages = request.get("messages")
                prompt = messages[-1].get("content") if isinstance(messages, list) and messages else None
                if not isinstance(prompt, str):
                    raise ValueError("invalid_prompt")
            except (ValueError, TypeError, json.JSONDecodeError):
                with state.lock:
                    state.problems.append("invalid_request")
                self.respond(400, {"error": "invalid mock request"})
                return

            with state.lock:
                state.requests.append({
                    "model": request.get("model"),
                    "stream": request.get("stream"),
                    "prompt": prompt,
                    "roles": [item.get("role") for item in messages if isinstance(item, dict)],
                })

            if prompt == "simulate header timeout":
                time.sleep(0.8)
                self.respond(200, {"model": "molly-e2e-mock", "message": {"role": "assistant", "content": "late reply"}})
            elif prompt == "simulate body timeout":
                body = json.dumps({"model": "molly-e2e-mock", "message": {
                    "role": "assistant", "content": "late body reply",
                }}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.flush()
                time.sleep(0.8)
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            elif prompt == "simulate provider error":
                self.respond(503, {"error": "mock provider unavailable"})
            elif prompt == "say hello":
                self.respond(200, {"model": "molly-e2e-mock", "message": {
                    "role": "assistant",
                    "content": "bestie @everyone <@123> here's a real transport check 💗",
                }})
            elif prompt == "recover please":
                self.respond(200, {"model": "molly-e2e-mock", "message": {
                    "role": "assistant", "content": "Molly recovered after a provider failure 🎀",
                }})
            else:
                with state.lock:
                    state.problems.append("unexpected_prompt")
                self.respond(400, {"error": "unexpected mock prompt"})

    return MockHandler


def main() -> int:
    runtime = os.environ.get("LUVIT_BIN")
    if not runtime:
        print("LUVIT_BIN must name the pinned/installed Luvit executable", file=sys.stderr)
        return 2
    executable = shutil.which(runtime) or (runtime if Path(runtime).is_file() else None)
    if not executable:
        print("Luvit executable was not found", file=sys.stderr)
        return 2

    state = State()
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="molly-mock-ollama", daemon=True)
    thread.start()

    env = os.environ.copy()
    env["MOLLY_TEST_OLLAMA_URL"] = f"http://127.0.0.1:{server.server_port}"
    env.setdefault("MOLLY_TEST_DEPS_DIR", str(ROOT / "deps"))
    try:
        result = subprocess.run(
            [executable, "tests/personality_ollama_e2e.lua"],
            cwd=ROOT,
            env=env,
            timeout=18,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print("Luvit E2E process exceeded its 18-second test limit", file=sys.stderr)
        return 124
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    with state.lock:
        requests = list(state.requests)
        problems = list(state.problems)

    if result.returncode != 0:
        return result.returncode
    if problems:
        print("mock server rejected one or more requests: " + ",".join(problems), file=sys.stderr)
        return 1
    if len(requests) != len(EXPECTED_PROMPTS):
        print(f"expected {len(EXPECTED_PROMPTS)} mock HTTP requests; received {len(requests)}", file=sys.stderr)
        return 1
    for index, (request, expected) in enumerate(zip(requests, EXPECTED_PROMPTS), start=1):
        if request["model"] != "molly-e2e-mock" or request["stream"] is not False or request["prompt"] != expected:
            print(f"mock request {index} did not match its expected model/protocol scenario", file=sys.stderr)
            return 1
        if request["roles"] != ["system", "user"]:
            print(f"mock request {index} did not contain the expected bounded prompt roles", file=sys.stderr)
            return 1

    print(f"mock Ollama server: {len(requests)} loopback HTTP requests verified; bot/DM/non-mention/duplicate filters produced no extra requests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

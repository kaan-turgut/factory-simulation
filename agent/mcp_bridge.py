#!/usr/bin/env python3
"""MCP stdio bridge to the headless Chocolate Works agent server.

Starts `godot --headless --script res://agent/server.gd` on a free local port, or connects with
--connect PORT to a server that is already running: a headless server, or the visible game started
with `-- --agent-port PORT` (live mode, where time commands play the shift on screen). Reads the
command list from the server's `describe` reply and exposes each command as an MCP tool named
`factory_<command>`.

Standard library only. Environment:
  GODOT_BIN   Godot executable (default: macOS app path, then `godot` on PATH)
"""

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAC_GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
PROTOCOL = "2025-06-18"
TYPES = {"string": "string", "number": "number", "int": "integer", "bool": "boolean", "array": "array"}


def log(message):
    print("[factory-bridge] " + message, file=sys.stderr, flush=True)


class Factory:
    def __init__(self, connect_port=None, scenario=None):
        self.process = None
        if connect_port is None:
            port = self._free_port()
            godot = os.environ.get("GODOT_BIN") or (MAC_GODOT if os.path.exists(MAC_GODOT) else shutil.which("godot"))
            if not godot:
                raise RuntimeError("Godot not found. Set GODOT_BIN.")
            command = [godot, "--headless", "--path", PROJECT, "--script", "res://agent/server.gd", "--", "--port", str(port)]
            if scenario:
                command += ["--scenario", scenario]
            self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self._wait_ready()
            connect_port = port
        # A live game replies to time commands only when the shift has played that far.
        self.sock = socket.create_connection(("127.0.0.1", connect_port), timeout=600 if self.process else None)
        self.reader = self.sock.makefile("r", encoding="utf-8")
        self.lock = threading.Lock()

    @staticmethod
    def _free_port():
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def _wait_ready(self):
        for line in self.process.stdout:
            if line.startswith("AGENT_SERVER_READY"):
                # Keep draining Godot output so its pipe never fills.
                threading.Thread(target=self._drain, daemon=True).start()
                return
            if "AGENT_SERVER_ERROR" in line:
                raise RuntimeError(line.strip())
        raise RuntimeError("Godot exited before the agent server was ready.")

    def _drain(self):
        for line in self.process.stdout:
            if "ERROR" in line:
                log("godot: " + line.rstrip())

    def call(self, cmd, args=None):
        with self.lock:
            self.sock.sendall((json.dumps({"cmd": cmd, "args": args or {}}) + "\n").encode())
            line = self.reader.readline()
        if not line:
            raise RuntimeError("The agent server closed the connection.")
        return json.loads(line)

    def close(self):
        if self.process:
            try:
                self.call("shutdown")
            except Exception:
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


def schema(spec_args):
    properties, required = {}, []
    for name, spec in spec_args.items():
        optional = spec.startswith("optional")
        rest = spec[len("optional"):].strip() if optional else spec
        match = re.match(r"(\w+)", rest)
        kind = TYPES.get(match.group(1) if match else "", "string")
        note = rest.split(":", 1)[1].strip() if ":" in rest else ""
        prop = {"type": kind}
        if kind == "array":
            prop["items"] = {"type": "string"}
        if note:
            prop["description"] = note
        properties[name] = prop
        if not optional:
            required.append(name)
    return {"type": "object", "properties": properties, "required": required}


def tools(factory):
    described = factory.call("describe")
    result = []
    for name, spec in described["commands"].items():
        if name == "describe":
            continue
        result.append({"name": "factory_" + name, "description": spec["description"] + " " + described["units"],
                       "inputSchema": schema(spec["args"])})
    return result


def serve(factory):
    tool_list = None
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            continue
        method, ident = message.get("method"), message.get("id")
        if ident is None:
            continue  # Notifications need no reply.
        try:
            if method == "initialize":
                requested = message.get("params", {}).get("protocolVersion", PROTOCOL)
                result = {"protocolVersion": requested, "capabilities": {"tools": {}},
                          "serverInfo": {"name": "chocolate-works", "version": "0.1.0"},
                          "instructions": "Plan and run the Chocolate Works factory simulation. Time only moves when you call "
                                          "factory_advance or factory_run_until. Use factory_snapshot/factory_restore for what-if tests "
                                          "and factory_log_decision to record findings and recommendations. factory_status shows "
                                          "mode: in live mode a person is watching the game, time commands take real time "
                                          "(simulated seconds divided by the speed), so prefer run_until with stop events "
                                          "and spans of an hour or less."}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                tool_list = tool_list or tools(factory)
                result = {"tools": tool_list}
            elif method == "tools/call":
                params = message.get("params", {})
                name = params.get("name", "")
                if not name.startswith("factory_"):
                    raise ValueError("Unknown tool " + name)
                reply = factory.call(name[len("factory_"):], params.get("arguments") or {})
                result = {"content": [{"type": "text", "text": json.dumps(reply, separators=(",", ":"))}],
                          "isError": not reply.get("ok", False)}
            else:
                send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found: " + str(method)}})
                continue
            send({"jsonrpc": "2.0", "id": ident, "result": result})
        except Exception as error:  # Report and keep serving.
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": str(error)}})


def send(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connect", type=int, help="Use an agent server already listening on this port.")
    parser.add_argument("--scenario", help="Scenario to load at start, e.g. res://scenarios/constrained_shift.json")
    options = parser.parse_args()
    factory = Factory(options.connect, options.scenario)
    try:
        serve(factory)
    finally:
        factory.close()


if __name__ == "__main__":
    main()

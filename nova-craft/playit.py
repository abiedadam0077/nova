#!/usr/bin/env python3
# Select only a user-designated tunnel or the single unambiguous matching one.
# This helper never creates tunnels and never prints the agent secret.
import json
import re
import shlex
import socket
import sys
import time

TYPES = {"JAVA": "minecraft-java", "BEDROCK": "minecraft-bedrock"}


def load(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def unwrap(raw):
    if not isinstance(raw, dict):
        return {}, "invalid-response"
    status = str(raw.get("status", "")).lower()
    if status in ("fail", "error"):
        return {}, "api-error"
    data = raw.get("data")
    if isinstance(data, dict):
        return data, ""
    success = raw.get("success")
    if isinstance(success, dict):
        return success, ""
    return raw, ""


def tunnel_id(tunnel):
    return str(tunnel.get("tunnel_id") or tunnel.get("id") or "")


def pick_tunnel(tunnels, edition, requested_id):
    wanted = TYPES.get(edition.upper(), TYPES["JAVA"])
    expected_port = "udp" if edition.upper() == "BEDROCK" else "tcp"
    compatible = [t for t in tunnels
                  if str(t.get("tunnel_type") or "") == wanted
                  and str(t.get("port_type") or "").lower() == expected_port]
    if requested_id:
        selected = next((t for t in tunnels if tunnel_id(t) == requested_id), None)
        if selected is None:
            return None, "The selected Playit Tunnel was not returned by the agent.", "selection_required"
        if str(selected.get("tunnel_type") or "") != wanted or str(selected.get("port_type") or "").lower() != expected_port:
            return None, "Tunnel type unsupported for this Minecraft edition and transport.", "unsupported"
        return selected, "", ""
    if len(compatible) == 1:
        return compatible[0], "", ""
    if len(compatible) > 1:
        return None, "Several matching Playit Tunnels exist; select one in NOVA CRAFT.", "selection_required"
    if tunnels:
        return None, "Tunnel type unsupported for this Minecraft edition and transport.", "unsupported"
    return None, "This Playit agent has no Tunnel yet. Create one manually in Playit.", "not_created"


def tunnel_field(tunnel, name):
    direct = tunnel.get(name)
    if direct is not None and str(direct):
        return str(direct)
    config = tunnel.get("agent_config")
    fields = config.get("fields") if isinstance(config, dict) else None
    if isinstance(fields, dict) and fields.get(name) is not None:
        return str(fields[name])
    if isinstance(fields, list):
        for field in fields:
            if isinstance(field, dict) and str(field.get("name") or "") == name:
                return str(field.get("value") or field.get("default_value") or "")
    return ""


def parse_host_port(address, edition):
    address = address.replace("tcp://", "").replace("udp://", "")
    host, sep, raw_port = address.rpartition(":")
    if not sep:
        host, raw_port = address, "19132" if edition.upper() == "BEDROCK" else "25565"
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    try:
        port = int(raw_port)
        if not host or not 1 <= port <= 65535:
            raise ValueError("invalid host or port")
        return host, port
    except (TypeError, ValueError):
        return None, None


def encode_varint(value):
    out = bytearray()
    while True:
        part = value & 0x7f
        value >>= 7
        if value:
            out.append(part | 0x80)
        else:
            out.append(part)
            return bytes(out)


def recv_exact(sock, length):
    chunks = bytearray()
    while len(chunks) < length:
        block = sock.recv(length - len(chunks))
        if not block:
            raise OSError("connection closed")
        chunks.extend(block)
    return bytes(chunks)


def read_varint(sock):
    value = 0
    for shift in range(0, 35, 7):
        byte = recv_exact(sock, 1)[0]
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value
    raise ValueError("invalid VarInt")


def java_status_ping(host, port):
    # Java Server List Ping over TCP; a successful connect without its status
    # response is not accepted as a ready Minecraft endpoint.
    encoded_host = host.encode("utf-8")
    handshake = b"\x00" + encode_varint(767) + encode_varint(len(encoded_host)) + encoded_host + port.to_bytes(2, "big") + b"\x01"
    packet = encode_varint(len(handshake)) + handshake + b"\x01\x00"
    with socket.create_connection((host, port), timeout=6) as sock:
        sock.settimeout(6)
        sock.sendall(packet)
        packet_len = read_varint(sock)
        if packet_len <= 0 or packet_len > 65536:
            return False
        packet_id = read_varint(sock)
        json_len = read_varint(sock)
        if packet_id != 0 or json_len <= 0 or json_len > packet_len:
            return False
        payload = json.loads(recv_exact(sock, json_len).decode("utf-8", "replace"))
        return isinstance(payload, dict) and ("version" in payload or "players" in payload)


def bedrock_status_ping(host, port):
    # RakNet unconnected ping over UDP, including the documented offline magic.
    magic = bytes((0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe, 0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78))
    stamp = int(time.time() * 1000).to_bytes(8, "big", signed=False)
    packet = b"\x01" + stamp + magic + (123456789).to_bytes(8, "big", signed=False)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(6)
        sock.sendto(packet, (host, port))
        reply, _ = sock.recvfrom(4096)
    if len(reply) < 35 or reply[0] != 0x1c or reply[17:33] != magic:
        return False
    text_len = int.from_bytes(reply[33:35], "big")
    if text_len <= 0 or 35 + text_len > len(reply):
        return False
    fields = reply[35:35 + text_len].decode("utf-8", "replace").split(";")
    return len(fields) >= 2 and bool(fields[0])


def probe(address, edition):
    host, port = parse_host_port(address, edition)
    if not host:
        return False
    try:
        if edition.upper() == "BEDROCK":
            return bedrock_status_ping(host, port)
        return java_status_ping(host, port)
    except (OSError, ValueError, json.JSONDecodeError):
        return False


def parse(argv):
    raw = load(argv[0])
    out_path = argv[1]
    edition = argv[2] if len(argv) > 2 else "JAVA"
    requested_id = argv[3] if len(argv) > 3 else ""
    if raw is None:
        data, error = {}, "invalid-json"
    else:
        data, error = unwrap(raw)
    raw_tunnels = data.get("tunnels") if not error else None
    if not error and (not isinstance(data.get("agent_id"), str) or not data.get("agent_id") or not isinstance(raw_tunnels, list)):
        error = "invalid-schema"
    if not error:
        for tunnel in raw_tunnels:
            if (not isinstance(tunnel, dict)
                    or not isinstance(tunnel.get("id") or tunnel.get("tunnel_id"), str)
                    or not (tunnel.get("id") or tunnel.get("tunnel_id"))
                    or not isinstance(tunnel.get("name"), str)
                    or not isinstance(tunnel.get("port_type"), str)
                    or not isinstance(tunnel.get("display_address"), str)):
                error = "invalid-schema"
                break
    tunnels = raw_tunnels if not error else []
    chosen, message, selection_state = pick_tunnel(tunnels, edition, requested_id) if not error else (None, "", "error")
    diagnostic = {
        "invalid-json": "rundata_invalid_json",
        "invalid-schema": "rundata_invalid_schema",
        "invalid-response": "rundata_invalid_response",
        "api-error": "rundata_api_error",
    }.get(error, "")
    error_message = {
        "invalid-json": "Playit rundata response was not valid JSON.",
        "invalid-schema": "Playit rundata did not contain a valid agent ID and Tunnel list.",
        "invalid-response": "Playit rundata response had an unexpected JSON shape.",
        "api-error": "Playit agent API returned an error response.",
    }.get(error, "Playit rundata could not be interpreted.")
    values = {
        "AGENT_ID": str(data.get("agent_id") or ""),
        "TUNNEL_STATE": "error",
        "TUNNEL_DIAGNOSTIC": diagnostic,
        "TUNNEL_Q_MSG": "",
        "TUNNEL_ADDR": "",
        "TUNNEL_NAME": "",
        "TUNNEL_ID": "",
        "TUNNEL_PROTO": "",
        "TUNNEL_LOCAL_IP": "",
        "TUNNEL_LOCAL_PORT": "",
        "TUNNEL_ISSUE": "",
    }
    if error:
        values["TUNNEL_Q_MSG"] = error_message
    elif chosen:
        reason = chosen.get("disabled_reason")
        if isinstance(reason, dict):
            reason = reason.get("type") or "disabled"
        values["TUNNEL_STATE"] = "disabled" if reason else "allocated"
        values["TUNNEL_ADDR"] = str(chosen.get("display_address") or "")
        values["TUNNEL_NAME"] = str(chosen.get("name") or "")
        values["TUNNEL_ID"] = tunnel_id(chosen)
        values["TUNNEL_PROTO"] = str(chosen.get("port_type") or "")
        values["TUNNEL_LOCAL_IP"] = tunnel_field(chosen, "local_ip")
        local_port = tunnel_field(chosen, "local_port")
        if re.fullmatch(r"[0-9]{1,5}", local_port) and 1 <= int(local_port) <= 65535:
            values["TUNNEL_LOCAL_PORT"] = local_port
        values["TUNNEL_ISSUE"] = str(reason or "")
        if not values["TUNNEL_ADDR"]:
            values["TUNNEL_STATE"] = "address_unavailable"
            values["TUNNEL_Q_MSG"] = "Playit has not allocated a public address for this Tunnel yet."
    else:
        values["TUNNEL_STATE"] = selection_state
        values["TUNNEL_Q_MSG"] = message
    if not values["TUNNEL_DIAGNOSTIC"]:
        values["TUNNEL_DIAGNOSTIC"] = values["TUNNEL_STATE"]
    with open(out_path, "w", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write("%s=%s\n" % (key, shlex.quote(value)))
    print("tunnel state: %s" % values["TUNNEL_STATE"])
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "parse" and len(sys.argv) >= 4:
        sys.exit(parse(sys.argv[2:]))
    if len(sys.argv) == 4 and sys.argv[1] == "probe":
        sys.exit(0 if probe(sys.argv[2], sys.argv[3]) else 1)
    print("usage: playit.py parse <rundata.json> <out.env> [edition] [tunnel_id] | probe <address> <edition>", file=sys.stderr)
    sys.exit(2)

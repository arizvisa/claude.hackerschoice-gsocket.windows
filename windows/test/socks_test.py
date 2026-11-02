import socket, struct, sys, time

"""
Raw SOCKS protocol test client - speaks SOCKS4/4a/5 bytes directly,
no compiler/toolchain needed. Verifies tools/socks.c's wire-protocol
handling for each variant against a running gs-netcat.exe SOCKS server.

Usage: socks_test.py <socks_port> <dst_port> [4|4a|5|5h]
  4   - SOCKS4, raw IPv4 address (default, original test)
  4a  - SOCKS4a, hostname-based addressing (IP byte pattern 0.0.0.x)
  5   - SOCKS5, IPv4 address type (ATYP=0x01)
  5h  - SOCKS5, domain-name address type (ATYP=0x03)

Hostname tests use the literal string "127.0.0.1" as the "hostname" -
GS_hton() (lib/gsocket-util.c) checks inet_addr() before falling back
to gethostbyname(), so this exercises the hostname wire-parsing path
(resolvehostname() in socks.c) without any real DNS dependency.
"""

socks_port = int(sys.argv[1])
dst_port = int(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else "4"

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(("127.0.0.1", socks_port))

if mode == "4":
    req = struct.pack("!BBH", 4, 1, dst_port) + socket.inet_aton("127.0.0.1") + b"user\x00"
    s.sendall(req)
    resp = s.recv(8)
    print("SOCKS4 reply:", resp)
    ok = len(resp) >= 2 and resp[1] == 0x5a

elif mode == "4a":
    req = (struct.pack("!BBH", 4, 1, dst_port) + b"\x00\x00\x00\x01"
           + b"user\x00" + b"127.0.0.1\x00")
    s.sendall(req)
    resp = s.recv(8)
    print("SOCKS4a reply:", resp)
    ok = len(resp) >= 2 and resp[1] == 0x5a

elif mode == "5":
    s.sendall(b"\x05\x01\x00")  # ver5, 1 method, no-auth
    auth_resp = s.recv(2)
    print("SOCKS5 auth reply:", auth_resp)
    if auth_resp != b"\x05\x00":
        print("SOCKS_AUTH_FAIL")
        sys.exit(1)
    req = b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", dst_port)
    s.sendall(req)
    resp = s.recv(10)
    print("SOCKS5 connect reply:", resp)
    ok = len(resp) >= 2 and resp[0] == 0x05 and resp[1] == 0x00

elif mode == "5h":
    s.sendall(b"\x05\x01\x00")
    auth_resp = s.recv(2)
    print("SOCKS5 auth reply:", auth_resp)
    if auth_resp != b"\x05\x00":
        print("SOCKS_AUTH_FAIL")
        sys.exit(1)
    host = b"127.0.0.1"
    req = b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", dst_port)
    s.sendall(req)
    resp = s.recv(10)
    print("SOCKS5 (hostname) connect reply:", resp)
    ok = len(resp) >= 2 and resp[0] == 0x05 and resp[1] == 0x00

else:
    print("unknown mode:", mode)
    sys.exit(1)

if not ok:
    print("SOCKS_CONNECT_FAIL")
    sys.exit(1)
print("SOCKS_CONNECT_OK")

msg = b"hello-via-socks-" + mode.encode() + b"-" + str(time.time()).encode()
s.sendall(msg)
data = s.recv(4096)
print("received:", data)
print("ROUNDTRIP_OK" if data == msg else "ROUNDTRIP_MISMATCH")
if data != msg:
    sys.exit(1)
s.close()

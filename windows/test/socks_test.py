import socket, struct, sys, time

socks_port = int(sys.argv[1])
dst_port = int(sys.argv[2])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(("127.0.0.1", socks_port))

req = struct.pack("!BBH", 4, 1, dst_port) + socket.inet_aton("127.0.0.1") + b"user\x00"
s.sendall(req)
resp = s.recv(8)
print("SOCKS reply:", resp)
if len(resp) >= 2 and resp[1] == 0x5a:
    print("SOCKS_CONNECT_OK")
else:
    print("SOCKS_CONNECT_FAIL")
    sys.exit(1)

msg = b"hello-via-socks-" + str(time.time()).encode()
s.sendall(msg)
data = s.recv(4096)
print("received:", data)
print("ROUNDTRIP_OK" if data == msg else "ROUNDTRIP_MISMATCH")
s.close()

import socket
import sys
import time

port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(("127.0.0.1", port))
msg = b"hello-through-the-tunnel-" + str(time.time()).encode()
print("sending: %r" % msg, flush=True)
s.sendall(msg)
data = s.recv(4096)
print("received: %r" % data, flush=True)
if data == msg:
    print("ROUNDTRIP_OK", flush=True)
else:
    print("ROUNDTRIP_MISMATCH", flush=True)
s.close()

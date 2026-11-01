import socket
import sys

port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
print("echo-server listening on %d" % port, flush=True)
while True:
    conn, addr = s.accept()
    print("echo-server accepted connection", flush=True)
    while True:
        data = conn.recv(4096)
        if not data:
            break
        print("echo-server got: %r" % data, flush=True)
        conn.sendall(data)
    conn.close()
    print("echo-server session done, waiting for next", flush=True)

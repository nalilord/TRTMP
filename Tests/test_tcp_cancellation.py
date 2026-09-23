#!/usr/bin/env python3
"""Fill a loopback listen backlog, then cancel an in-flight TCP connect."""

import select
import socket
import subprocess
import time
from pathlib import Path


BINARY = Path(__file__).resolve().parents[1] / "Bin/linux/RtmpTcpCancellationSmoke"


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        fillers = []
        try:
            for _ in range(20):
                connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                connection.setblocking(False)
                connection.connect_ex(listener.getsockname())
                fillers.append(connection)
            time.sleep(0.1)
            ready = select.select([], fillers, [], 0)[1]
            assert len(ready) < len(fillers) - 2, "listen backlog did not fill"
            result = subprocess.run(
                [str(BINARY), str(listener.getsockname()[1])],
                capture_output=True, text=True, timeout=3,
            )
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            assert "TCP in-flight cancellation passed" in result.stdout
        finally:
            for connection in fillers:
                connection.close()
    print("backlogged TCP connect cancellation passed")


if __name__ == "__main__":
    main()

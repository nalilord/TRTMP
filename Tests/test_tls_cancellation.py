#!/usr/bin/env python3
"""Cancel an outbound TLS handshake while its local peer stays silent."""

import socket
import subprocess
import threading
import time
from pathlib import Path


BINARY = Path(__file__).resolve().parents[1] / "Bin/linux/RtmpTlsCancellationSmoke"


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def silent_peer():
            connection, _ = listener.accept()
            with connection:
                time.sleep(0.8)

        worker = threading.Thread(target=silent_peer, daemon=True)
        worker.start()
        result = subprocess.run(
            [str(BINARY), str(listener.getsockname()[1])],
            capture_output=True, text=True, timeout=3,
        )
        worker.join(timeout=2)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        assert "TLS handshake cancellation passed" in result.stdout
    print("silent TLS peer cancellation passed")


if __name__ == "__main__":
    main()

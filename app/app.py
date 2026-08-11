from flask import Flask, request, Response
import os
import requests

app = Flask(__name__)


@app.route("/")
def index():
    return (
        "Metadata Mirage - internal link-preview service\n"
        "Usage: /fetch?url=https://example.com\n"
    )


# INTENTIONALLY VULNERABLE.
# Fetches whatever URL the caller supplies, server-side, with no
# allow-list and no block on link-local (169.254.169.254) targets.
# That is the whole bug: a classic SSRF that can reach the instance
# metadata service on behalf of the attacker.
@app.route("/fetch")
def fetch():
    url = request.args.get("url", "")
    if not url:
        return "missing url parameter", 400
    try:
        r = requests.get(url, timeout=5)
        return Response(r.text, status=r.status_code, content_type="text/plain")
    except Exception as e:
        return "fetch error: " + str(e), 502


if __name__ == "__main__":
    port = int(os.environ.get("APP_PORT", "5000"))
    app.run(host="0.0.0.0", port=port)

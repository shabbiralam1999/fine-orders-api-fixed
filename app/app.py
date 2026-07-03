import os

from flask import Flask, jsonify

app = Flask(__name__)

# App configuration
# SECRET_KEY must always come from the environment. We fail fast if it's
# missing rather than silently falling back to an insecure default — that
# fallback is exactly what lets a misconfigured deployment go out with a
# well-known, guessable key. docker-compose.yml and .env.example both set
# SECRET_KEY for local development, so this should "just work" there;
# CI sets a throwaway value for the test job (see ci.yml).
try:
    app.config["SECRET_KEY"] = os.environ["SECRET_KEY"]
except KeyError:
    raise RuntimeError(
        "SECRET_KEY environment variable is not set. "
        "Copy .env.example to .env (or export SECRET_KEY) before running the app."
    ) from None


@app.route("/")
def index():
    return jsonify({"service": "orders-api", "status": "ok"})


@app.route("/healthz")
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/orders")
def orders():
    return jsonify({"orders": [{"id": 1, "item": "widget", "qty": 3}]})


if __name__ == "__main__":
    # Only used for local/manual runs. In the container we run via gunicorn (see Dockerfile).
    debug_mode = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=debug_mode)

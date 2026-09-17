import os
from flask import Flask, jsonify

app = Flask(__name__)

@app.route("/")
def index():
    return jsonify(message="Hello from GateFlow", version=os.environ.get("APP_VERSION", "v1"))

# Kubernetes will call this constantly later - keep it separate from '/'
# and free of any dependency (no DB calls etc.) so it never fails for
# unrelated reasons.
@app.route("/health")
def health():
    return "ok", 200

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 3000))
    app.run(host="0.0.0.0", port=port)

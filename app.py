import os
from flask import Flask, jsonify

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

@app.route("/mcp", methods=["GET", "POST"])
def mcp():
    return jsonify({
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "serverInfo": {"name": "matlama-mt5-bridge", "version": "1.0.0"}
    })

if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    app.run(host="0.0.0.0", port=port)

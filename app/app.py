from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time

from flask import Flask, jsonify, request, Response

import socket
import datetime
import pymysql

from config import DB_CONFIG

app = Flask(__name__)

REQUEST_COUNT = Counter(
    "flask_http_requests_total",
    "Total number of HTTP requests",
    ["method", "endpoint", "status"]
)

REQUEST_LATENCY = Histogram(
    "flask_http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["endpoint"]
)

@app.before_request
def before_request():
    request.start_time = time.time()


@app.after_request
def after_request(response):
    endpoint = request.endpoint or "unknown"

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status=response.status_code
    ).inc()

    if hasattr(request, "start_time"):
        REQUEST_LATENCY.labels(
            endpoint=endpoint
        ).observe(time.time() - request.start_time)

    return response


@app.route("/metrics")
def metrics():
    return Response(
        generate_latest(),
        mimetype=CONTENT_TYPE_LATEST
    )


@app.route("/")
def index():
    return "SRE-Lab Python Service Running"


@app.route("/api/status")
def status():
    return jsonify({
        "status": "running",
        "server": socket.gethostname(),
        "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })

@app.route("/api/servers",methods=["GET","POST"])
def servers():
    conn = pymysql.connect(**DB_CONFIG)

    try:
        if request.method == "GET":
            with conn.cursor(pymysql.cursors.DictCursor) as cursor:
                cursor.execute(
                        "SELECT id, hostname, ip, status, update_time FROM server_info"
                )
                rows = cursor.fetchall()
            return jsonify(rows)
        elif request.method == "POST":
            data = request.get_json()

            hostname = data.get("hostname")
            ip = data.get("ip")
            status = data.get("status", "running")

            with conn.cursor() as cursor:
                sql = """
                insert into server_info(hostname,ip,status)
                values (%s,%s,%s)
                """
                cursor.execute(sql,(hostname,ip,status))

            conn.commit()

            return jsonify({
                "message": "server added successfully"
            }),201
                        
    finally:
        conn.close()

@app.route("/api/servers/<int:server_id>",methods=["PUT"])
def update_server(server_id):
    data = request.get_json()
    status = data.get("status")

    if not status:
        return jsonoify({
            "error": "status is required"
        }),400

    conn = pymysql.connect(**DB_CONFIG)

    try:
        with conn.cursor() as cursor:
            sql = """
            update server_info
            set status = %s
            where id = %s
            """
            cursor.execute(sql,(status,server_id))

        conn.commit()

        if cursor.rowcount == 0:
            return jsonify({
                "error":"server not found"
            }),404

        return jsonify({
            "message":"server status updated successfully"
        })

    finally:
        conn.close()

@app.route("/api/servers/<int:server_id>",methods=["DELETE"])
def delete_server(server_id):
    conn = pymysql.connect(**DB_CONFIG)

    try:
        with conn.cursor() as cursor:
            sql = """
            DELETE FROM server_info
            WHERE id = %s
            """
            cursor.execute(sql, (server_id,))

            if cursor.rowcount == 0:
                return jsonify({
                    "error": "server not found"
                }), 404

        conn.commit()

        return jsonify({
            "message": "server deleted successfully"
        })

    finally:
        conn.close()
        

if __name__ == "__main__":
    app.run(host="127.0.0.1",port=8000)

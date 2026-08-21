import os

DB_CONFIG = {
        "host": os.getenv("DB_HOST","127.0.0.1"),
        "user": os.getenv("DB_USER","sre_app"),
        "password": os.getenv("DB_PASSWORD"),
        "database": os.getenv("DB_NAME","sre_db"),
        "charset": "utf8mb4"
}

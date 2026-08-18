# Python Web Service Deployment


## Overview

Deploy a Flask API service behind Nginx.


Architecture:

Client
 |
Nginx :80
 |
Flask :8000
 |
Python


## Environment

- Python 3.9
- Flask
- Rocky Linux 9


## Virtual Environment

Created isolated environment:

python3 -m venv venv


Install:

pip install flask


## API

GET /api/status

Response:

{
    "status":"running",
    "server":"sre-lab"
}


## Nginx Reverse Proxy

Nginx forwards requests:

80 --> 8000


## Systemd Management

Created:

/etc/systemd/system/sre-app.service


Commands:

systemctl start sre-app

systemctl restart sre-app

systemctl enable sre-app


## Troubleshooting

Problem:

systemd failed to start service.


Cause:

Port 8000 already occupied.


Solution:

Check port:

ss -tnlp

Check logs:

journalctl -u sre-app
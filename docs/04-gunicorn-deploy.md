# Gunicorn Deployment

## Architecture

Nginx
 |
Gunicorn
 |
Flask


## Why Gunicorn

Flask development server is not suitable for production.

Gunicorn provides a production WSGI server.


## Systemd

Managed application lifecycle:

systemctl start sre-app
systemctl restart sre-app
systemctl enable sre-app


## Troubleshooting

Problem:
Port 8000 already in use.

Cause:
Old Flask process occupied the port.

Solution:
Check process and restart service.
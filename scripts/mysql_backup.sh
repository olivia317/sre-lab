#!/bin/bash

BACKUP_DIR="/home/sre/backups/mysql"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/sre_db_${DATE}.sql"
LOG_FILE="${BACKUP_DIR}/backup.log"

mkdir -p "$BACKUP_DIR"

mysqldump sre_db > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "[$(date '+%F %T')] Backup success: $BACKUP_FILE" >> "$LOG_FILE"
    find "$BACKUP_DIR" \
    	-type f \
    	-name "sre_db_*.sql" \
    	-mtime +7 \
    	-delete
else
    echo "[$(date '+%F %T')] Backup failed" >> "$LOG_FILE"
    rm -f "$BACKUP_FILE"
    exit 1
fi

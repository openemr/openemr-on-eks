#!/bin/sh
# Runs inside the data-restore Job container.
# Downloads app-data tarball from S3, extracts to EFS, updates sqlconf.php.

set -eu

echo "OpenEMR data restore job starting (version: ${OPENEMR_VERSION:-unknown})"

apk add --no-cache aws-cli >/dev/null 2>&1 || true
aws --version || { echo "ERROR: AWS CLI unavailable"; exit 1; }

APP_KEY="${APP_DATA_KEY:-application-data/app-data-backup-${TIMESTAMP}.tar.gz}"
echo "Using app data key: s3://${BACKUP_BUCKET}/${APP_KEY}"

aws s3 cp "s3://${BACKUP_BUCKET}/${APP_KEY}" /tmp/app-data.tar.gz
ls -lh /tmp/app-data.tar.gz

echo "Extracting to EFS..."
# The restore container drops every Linux capability, including CHOWN.
# Preserve the access point's enforced ownership instead of replaying archive owners.
tar --no-same-owner -xzf /tmp/app-data.tar.gz -C /mnt/efs/ --strip-components=1
ls -la /mnt/efs/default/ 2>/dev/null || ls -la /mnt/efs/

if [ -z "${DB_ENDPOINT:-}" ] || [ -z "${DB_PASS:-}" ]; then
  echo "ERROR: DB_ENDPOINT and DB_PASS required"
  exit 1
fi

if [ -f "/mnt/efs/default/sqlconf.php" ]; then
  cp /mnt/efs/default/sqlconf.php /mnt/efs/default/sqlconf.php.backup
  printf '<?php\n//  OpenEMR\n//  MySQL Config\n\nglobal $disable_utf8_flag;\n$disable_utf8_flag = false;\n\n$host   = '\''%s'\'';\n$port   = '\''3306'\'';\n$login  = '\''%s'\'';\n$pass   = '\''%s'\'';\n$dbase  = '\''%s'\'';\n$db_encoding = '\''utf8mb4'\'';\n\n$sqlconf = [];\nglobal $sqlconf;\n$sqlconf["host"] = $host;\n$sqlconf["port"] = $port;\n$sqlconf["login"] = $login;\n$sqlconf["pass"] = $pass;\n$sqlconf["dbase"] = $dbase;\n$sqlconf["db_encoding"] = $db_encoding;\n\n$config = 1;\n' \
    "${DB_ENDPOINT}" "${DB_USER:-openemr}" "${DB_PASS}" "${DB_NAME:-openemr}" \
    > /mnt/efs/default/sqlconf.php
  echo "Updated sqlconf.php for endpoint ${DB_ENDPOINT}"
else
  echo "WARNING: sqlconf.php not in backup; creating minimal config"
  printf '<?php\n$host="%s";$port="3306";$login="%s";$pass="%s";$dbase="%s";$db_encoding="utf8mb4";$sqlconf=[];global $sqlconf;$sqlconf["host"]=$host;$sqlconf["port"]=$port;$sqlconf["login"]=$login;$sqlconf["pass"]=$pass;$sqlconf["dbase"]=$dbase;$sqlconf["db_encoding"]=$db_encoding;$config=1;\n' \
    "${DB_ENDPOINT}" "${DB_USER:-openemr}" "${DB_PASS}" "${DB_NAME:-openemr}" \
    > /mnt/efs/default/sqlconf.php
fi

rm -f /mnt/efs/default/docker-leader /mnt/efs/default/docker-initiated
touch /mnt/efs/default/docker-completed

echo "Data restore job completed successfully"

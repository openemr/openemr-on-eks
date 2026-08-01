#!/usr/bin/env bash
# Seed self-signed SSL certs on openemr-ssl-pvc before OpenEMR starts Apache.
#
# After backup/restore, sites/ on EFS contains docker-completed so OpenEMR skips
# first-boot SSL setup, but openemr-ssl-pvc is a new empty volume. Mounting the
# PVC at /etc/ssl hides openssl.cnf from the image; bootstrap via a side mount.

set -euo pipefail

NAMESPACE="${NAMESPACE:-openemr}"
OPENEMR_VERSION="${OPENEMR_VERSION:-8.2.0}"
SSL_CERT_BOOTSTRAP_TIMEOUT="${SSL_CERT_BOOTSTRAP_TIMEOUT:-300}"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "kubectl is not configured; skipping SSL cert bootstrap" >&2
    exit 1
fi

if ! kubectl get pvc openemr-ssl-pvc -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "openemr-ssl-pvc not found in namespace $NAMESPACE" >&2
    exit 1
fi

JOB_NAME="ssl-cert-bootstrap-$(date +%Y%m%d-%H%M%S)"
echo "Bootstrapping SSL certificates via job: $JOB_NAME"

kubectl delete job -n "$NAMESPACE" -l app=ssl-cert-bootstrap --ignore-not-found --wait=true 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ssl-cert-bootstrap
spec:
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: openemr-sa
      containers:
      - name: ssl-bootstrap
        image: openemr/openemr:${OPENEMR_VERSION}
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          SSL_ROOT=/mnt/ssl-efs
          if [ -f "\$SSL_ROOT/certs/webserver.cert.pem" ] && [ -f "\$SSL_ROOT/apache2/server.pem" ]; then
            echo "SSL certificates already present on openemr-ssl-pvc"
            exit 0
          fi
          mkdir -p "\$SSL_ROOT/certs" "\$SSL_ROOT/private" "\$SSL_ROOT/apache2"
          OPENSSL_CNF=""
          for c in /etc/ssl/openssl.cnf /etc/pki/tls/openssl.cnf /usr/lib/ssl/openssl.cnf; do
            [ -f "\$c" ] && OPENSSL_CNF="\$c" && break
          done
          if [ -z "\$OPENSSL_CNF" ]; then
            OPENSSL_CNF=\$(find /usr /etc -name 'openssl.cnf' 2>/dev/null | head -1)
          fi
          if [ -z "\$OPENSSL_CNF" ] || [ ! -f "\$OPENSSL_CNF" ]; then
            echo "Could not locate openssl.cnf" >&2
            exit 1
          fi
          cp "\$OPENSSL_CNF" "\$SSL_ROOT/openssl.cnf"
          export OPENSSL_CONF="\$SSL_ROOT/openssl.cnf"
          openssl req -x509 -newkey rsa:2048 -nodes \\
            -keyout "\$SSL_ROOT/private/selfsigned.key.pem" \\
            -out "\$SSL_ROOT/certs/selfsigned.cert.pem" \\
            -days 3650 -subj "/CN=openemr.local/O=OpenEMR"
          cd "\$SSL_ROOT/certs" && ln -sf selfsigned.cert.pem webserver.cert.pem
          cd "\$SSL_ROOT/private" && ln -sf selfsigned.key.pem webserver.key.pem
          ln -sf ../certs/selfsigned.cert.pem "\$SSL_ROOT/apache2/server.pem"
          ln -sf ../private/selfsigned.key.pem "\$SSL_ROOT/apache2/server.key"
          echo "SSL bootstrap complete"
        volumeMounts:
        - name: openemr-ssl
          mountPath: /mnt/ssl-efs
      volumes:
      - name: openemr-ssl
        persistentVolumeClaim:
          claimName: openemr-ssl-pvc
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
        effect: NoSchedule
EOF

if ! kubectl wait --for=condition=complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout="${SSL_CERT_BOOTSTRAP_TIMEOUT}s"; then
    echo "SSL bootstrap job failed; logs:" >&2
    kubectl logs "job/$JOB_NAME" -n "$NAMESPACE" || true
    exit 1
fi

echo "SSL certificates ready on openemr-ssl-pvc."

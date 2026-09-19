#!/bin/bash
# LAB5 — generate our own age identity and put it in the cluster.
#
# The shipped maps are encrypted to a recipient whose private identity this
# repository does not have, so we make our own pair and encrypt our own corpus
# to it -- the same path, with a key we hold.
#
# The identity file is written OUTSIDE the repository on purpose. A private key
# committed once is compromised forever, and .gitignore is not a control -- it
# is a convenience that the next `git add -f` defeats.
set -euo pipefail
KEYDIR="$HOME/.config/xray-memory"
KEYFILE="$KEYDIR/snapshot.key"
XRAY_IMG=ghcr.io/den-vasyliev/abox/xray-memory:v1.23.66-61e4eaa

mkdir -p "$KEYDIR"
if [ -f "$KEYFILE" ]; then
  echo "identity already exists at $KEYFILE — keeping it"
else
  # The container writes as uid 65532, so generate into a world-writable temp
  # dir and move it into place with the permissions a private key should have.
  TMP=$(mktemp -d); chmod 777 "$TMP"
  # --user is not a detail here. keygen writes mode 0600, so a file created by
  # the image's own uid 65532 cannot afterwards be read, moved or chmod'ed by
  # the person whose key it is.
  docker run --rm --user "$(id -u):$(id -g)" -v "$TMP":/out "$XRAY_IMG" \
    keygen -out /out/snapshot.key
  umask 077
  cat "$TMP/snapshot.key" > "$KEYFILE"
  rm -f "$TMP/snapshot.key"; rmdir "$TMP"
  chmod 600 "$KEYFILE"
  echo "wrote $KEYFILE"
fi

echo "=== public recipient (safe to share, this is what encrypts):"
RECIPIENT=$(grep -o 'age1[a-z0-9]*' "$KEYFILE" | head -1)
if [ -z "$RECIPIENT" ]; then
  # keygen writes the recipient as a comment; if this build does not, derive it
  RECIPIENT=$(docker run --rm -v "$KEYDIR":/k "$XRAY_IMG" keygen -y /k/snapshot.key 2>/dev/null | grep -o 'age1[a-z0-9]*' | head -1)
fi
echo "$RECIPIENT"
echo "$RECIPIENT" > "$KEYDIR/recipient.txt"

echo "=== putting the identity in the cluster"
kubectl create namespace xray-memory --dry-run=client -o yaml | kubectl apply -f -
kubectl -n xray-memory delete secret xray-memory-snapshot-key --ignore-not-found
kubectl -n xray-memory create secret generic xray-memory-snapshot-key \
  --from-file=identity="$KEYFILE"
echo "done"

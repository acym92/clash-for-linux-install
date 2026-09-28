#!/usr/bin/env bash

# Invoke this from the container's existing entrypoint after its own setup.
# CLASHCTL_HOME is the installation directory, not the source checkout.
: "${CLASHCTL_HOME:?请设置 CLASHCTL_HOME 为实际安装路径}"
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
clashctl on --service-only || true
# Keep the container alive while the background supervisor retries failures.
exec sleep infinity

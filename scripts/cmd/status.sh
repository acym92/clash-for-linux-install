#!/usr/bin/env bash

function clashstatus() {
    service_status "$@"
    _supervisor_status
    service_is_active >&/dev/null
}

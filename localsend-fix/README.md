# LocalSend VPN Fix

This directory contains the Windows x64 portable build of LocalSend with the
VPN connection fix.

## Install

1. Download `LocalSend-Fix-Windows-x64.zip`.
2. Extract it to any folder.
3. Run `localsend_app.exe`.

The fix disables system/VPN proxy interception for LocalSend's direct local
peer connections. This prevents requests to private LAN addresses such as
`192.168.x.x` from failing during TLS/request setup.

The build was validated with the LocalSend Rust core test suite: 59 tests
passed.

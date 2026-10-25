# __NAME__

A module for [sitectl](https://example.com/sitectl).

## What it does

Describe it here.

## Settings

| Setting | |
|---|---|
| `__NAME__.greeting` | What to say when a site is added |
| `__NAME__.api_token` | An API token (secret) |

## Making a release

1. Bump `version` in `module.conf`.
2. `sitectl modules pack __NAME__.pkg` writes `CHECKSUMS` and makes
   `__NAME__-<version>.tar.gz`.
3. On the server: `sudo sitectl modules install __NAME__-<version>.tar.gz`.
   The previous version is kept in `/etc/sitectl/backups/`.

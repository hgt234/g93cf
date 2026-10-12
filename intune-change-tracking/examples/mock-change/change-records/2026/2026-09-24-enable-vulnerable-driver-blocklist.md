---
policy: "Windows - Security Baseline"
object_id: "11111111-1111-1111-1111-111111111111"
environment: "production"
target: "All corporate Windows devices"
ticket: "SEC-1842"
change_type: "planned"
valid_until_utc: "2099-12-31T23:59:59Z"
---

# Summary

Enable the vulnerable driver blocklist.

## Why

Required by SEC-1842 to prevent known vulnerable kernel drivers.

## Validation

- [x] Confirm the intended assignment in Intune.
- [x] Confirm the next snapshot diff matches this record.

## Rollback

Set the vulnerable driver blocklist value back to false.


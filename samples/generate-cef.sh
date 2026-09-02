#!/usr/bin/env bash
# Regenerates samples/cef.log — the CEF replay set fed to blitz's filegen
# generator.
#
# WHY THIS EXISTS, rather than using package:universal-cef:
# Bindplane's common_event_format source parses with this operator chain:
#   1. regex_parser  '^(?P<timestamp>\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+
#                      ((?P<hostname>[^\s]+)\s+)?(?P<cef_headers>[\d\D]+)'
#   2. csv_parser    splits cef_headers on '|'
#   3. severity_parser
# The first regex REQUIRES a syslog-style "Jan 02 15:04:05 host" prefix ahead of
# the CEF payload. The universal-cef library samples are bare "CEF:0|..." lines,
# so the regex never matches, the chain aborts, and records arrive completely
# unparsed — silently, with no error logged and throughput looking healthy.
#
# So every line here carries the prefix. Note %d (zero-padded day) and not %e
# (space-padded): the plugin's timestamp layout is gotime 'Jan 02 15:04:05', and
# a space-padded "Sep  2" does not match a "02" layout.
#
# filegen picks ONE RANDOM LINE per cycle, so the line-count ratio below is the
# severity mix on the wire. The low-severity majority is deliberate — it is the
# noise that makes filtering and volume reduction worth demonstrating.
#
# NOTE: cef.log cannot contain comments or blank-line headers — every non-empty
# line is emitted verbatim as a log record. Keep explanation here instead.

set -euo pipefail

OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cef.log"

TS='%b %d %T'          # -> "Sep 02 13:45:01", matches gotime 'Jan 02 15:04:05'
HOST='siem-edge-01'

NOISE_COUNT=40         # low-severity benign events (the noise to filter out)

# CEF header: CEF:Version|DeviceVendor|DeviceProduct|DeviceVersion|SignatureID|Name|Severity|Extensions
cef() { # $1=vendor $2=product $3=version $4=sigid $5=name $6=severity $7=extensions
  printf '%s\n' "${TS} ${HOST} CEF:0|$1|$2|$3|$4|$5|$6|$7"
}

: > "$OUT"

# --- noise: routine, low-severity, high-volume -------------------------------
srcs=(10.20.30.41 10.20.30.42 10.20.30.55 192.168.1.24 192.168.1.90 172.16.4.11)
users=(jsmith mgarcia tnguyen awilliams rpatel klee dcooper hokafor)
for i in $(seq 1 "$NOISE_COUNT"); do
  s=${srcs[$((i % ${#srcs[@]}))]}
  u=${users[$((i % ${#users[@]}))]}
  case $((i % 4)) in
    0) cef Network IDS 2.0 1001 Allowed_Traffic 1 \
         "src=${s} spt=$((40000 + i)) dst=198.51.100.20 dpt=443 proto=TCP act=allow cat=policy" >> "$OUT" ;;
    1) cef Identity IdP 1.2 2001 Auth_Success 1 \
         "src=${s} suser=${u} outcome=success cat=authentication" >> "$OUT" ;;
    2) cef Cloud WAF 1.5 3001 Request_Allowed 2 \
         "src=${s} dpt=80 request=/health act=allow cat=webrequest" >> "$OUT" ;;
    3) cef Endpoint EDR 4.0 4001 Process_Started 3 \
         "src=${s} suser=${u} sproc=/usr/bin/curl cat=process" >> "$OUT" ;;
  esac
done

# --- medium: worth looking at -------------------------------------------------
cef Network IDS 2.0 1100 Port_Scan_Detected 5 \
  "src=203.0.113.55 dst=10.20.30.41 dpt=22 proto=TCP act=block cat=recon" >> "$OUT"
cef Identity IdP 1.2 2100 Auth_Failed 5 \
  "src=203.0.113.61 suser=admin outcome=failure reason=bad_password cat=authentication" >> "$OUT"
cef Cloud WAF 1.5 3100 Rate_Limit_Triggered 4 \
  "src=203.0.113.77 dpt=443 request=/api/v1/login act=throttle cat=webrequest" >> "$OUT"
cef Endpoint EDR 4.0 4100 Unsigned_Binary 6 \
  "src=192.168.1.24 suser=rpatel sproc=/tmp/update cat=process" >> "$OUT"
cef Container Runtime 1.0 5100 Privileged_Container 6 \
  "src=10.20.30.55 cs1Label=image cs1=internal/batch:2.1 cat=container" >> "$OUT"
cef Secure DataLoss 1.1 6100 Policy_Warning 4 \
  "src=192.168.1.90 suser=klee fname=quarterly.xlsx cat=dlp" >> "$OUT"

# --- high: real signal --------------------------------------------------------
cef Network IDS 2.0 1200 Malware_Callback 8 \
  "src=10.20.30.42 dst=203.0.113.200 dpt=8080 proto=TCP cs1Label=family cs1=Trojan.Generic cat=malware" >> "$OUT"
cef Identity IdP 1.2 2200 Impossible_Travel 8 \
  "src=198.51.100.77 suser=dcooper cs1Label=geo cs1=SG-then-BR cat=authentication" >> "$OUT"
cef Cloud WAF 1.5 3200 SQL_Injection 7 \
  "src=203.0.113.100 dpt=80 request=/search act=block cat=webattack" >> "$OUT"
cef Endpoint EDR 4.0 4200 Credential_Dumping 8 \
  "src=192.168.1.24 suser=SYSTEM sproc=/usr/bin/procdump cat=credaccess" >> "$OUT"

# --- critical: page someone ---------------------------------------------------
cef Endpoint EDR 4.0 4300 Ransomware_Detected 10 \
  "src=192.168.1.24 suser=awilliams fname=encrypted.exe act=quarantine cat=malware" >> "$OUT"
cef Secure DataLoss 1.1 6300 Bulk_Exfiltration 9 \
  "src=192.168.1.90 dst=203.0.113.50 dpt=443 fsize=524288000 fname=customers.sql cat=dlp" >> "$OUT"
cef Identity IdP 1.2 2300 MFA_Bypass 9 \
  "src=192.0.2.150 suser=admin cs1Label=method cs1=compromised_mfa cat=authentication" >> "$OUT"
cef Network IDS 2.0 1300 Lateral_Movement 9 \
  "src=10.20.30.41 dst=10.20.30.99 dpt=445 proto=TCP act=block cat=lateral" >> "$OUT"

printf 'wrote %s (%s lines)\n' "$OUT" "$(grep -c . "$OUT")"

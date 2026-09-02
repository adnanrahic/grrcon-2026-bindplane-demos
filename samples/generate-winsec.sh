#!/usr/bin/env bash
# Regenerates samples/winsec.xml — the Windows Security replay set fed to
# blitz's filegen generator.
#
# filegen picks ONE RANDOM LINE per cycle, so the line-count ratio below is
# the event-mix ratio on the wire. NOISE_COUNT controls how much benign
# successful-logon traffic buries the interesting events.
#
# Timestamp directives (%Y-%m-%dT%H:%M:%S.%3NZ) are substituted by filegen at
# emit time, so replayed events always carry a current timestamp.
#
# NOTE: winsec.xml cannot contain comments or headers — every non-empty line
# is emitted verbatim as a log record. Keep the explanation here instead.

set -euo pipefail

OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/winsec.xml"

NOISE_COUNT=52   # 4624 successful logons (the noise to filter out)

PROVIDER='<Provider Name="Microsoft-Windows-Security-Auditing" Guid="{54849625-5478-4994-A5BA-3E3B0328C30D}"/>'
TS='%Y-%m-%dT%H:%M:%S.%3NZ'
DOMAIN='CONTOSO'

# filegen collapses the ctime directive %% into a single %. Windows writes
# FailureReason as the message-table ref %%2313, so it is written here as
# %%%2313 to survive substitution and land on the wire as %%2313.
FAILREASON='%%%2313'

users=(jsmith mgarcia tnguyen awilliams rpatel klee dcooper hokafor svc_backup svc_monitor bchen lmartin)
hosts=(WKS-001 WKS-002 WKS-004 WKS-007 WKS-011 WKS-014 WKS-019 WKS-023 LAP-005 LAP-012)
subnet=(10 11 12 14 15 21 22 33 41 55 67 88 91 104 117 130)
ltypes=(2 3 3 3 5 7 10 3 2 3)
lprocs=(Kerberos Kerberos NtLmSsp Negotiate Advapi User32 RDP Kerberos User32 Kerberos)

logon() { # $1=recordid $2=user $3=host $4=ip $5=logontype $6=logonproc $7=computer
  printf '%s\n' "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System>${PROVIDER}<EventID>4624</EventID><Version>2</Version><Level>0</Level><Task>12544</Task><Opcode>0</Opcode><Keywords>0x8020000000000000</Keywords><TimeCreated SystemTime=\"${TS}\"/><EventRecordID>$1</EventRecordID><Correlation/><Execution ProcessID=\"716\" ThreadID=\"760\"/><Channel>Security</Channel><Computer>$7</Computer><Security/></System><EventData><Data Name=\"SubjectUserSid\">S-1-5-18</Data><Data Name=\"SubjectUserName\">${7%%.*}\$</Data><Data Name=\"SubjectDomainName\">${DOMAIN}</Data><Data Name=\"SubjectLogonId\">0x3e7</Data><Data Name=\"TargetUserSid\">S-1-5-21-3623811015-3361044348-30300820-$((1000 + $1 % 400))</Data><Data Name=\"TargetUserName\">$2</Data><Data Name=\"TargetDomainName\">${DOMAIN}</Data><Data Name=\"TargetLogonId\">0x$(printf '%x' $((0x400000 + $1 * 977)))</Data><Data Name=\"LogonType\">$5</Data><Data Name=\"LogonProcessName\">$6</Data><Data Name=\"AuthenticationPackageName\">Negotiate</Data><Data Name=\"WorkstationName\">$3</Data><Data Name=\"LogonGuid\">{F67F7B2A-7E5C-4B8D-A1E2-3F4D5C6B7A8B}</Data><Data Name=\"TransmittedServices\">-</Data><Data Name=\"LmPackageName\">-</Data><Data Name=\"KeyLength\">128</Data><Data Name=\"ProcessId\">0x44c</Data><Data Name=\"ProcessName\">C:\\Windows\\System32\\lsass.exe</Data><Data Name=\"IpAddress\">$4</Data><Data Name=\"IpPort\">$((49152 + $1 % 9000))</Data><Data Name=\"ImpersonationLevel\">Impersonation</Data><Data Name=\"RestrictedAdminMode\">-</Data><Data Name=\"TargetOutboundUserName\">-</Data><Data Name=\"TargetOutboundDomainName\">-</Data><Data Name=\"VirtualAccount\">No</Data><Data Name=\"TargetLinkedLogonId\">0x0</Data><Data Name=\"ElevatedToken\">No</Data></EventData></Event>"
}

failed() { # $1=recordid $2=user $3=host $4=ip $5=logontype $6=status $7=substatus $8=computer
  printf '%s\n' "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System>${PROVIDER}<EventID>4625</EventID><Version>0</Version><Level>0</Level><Task>12546</Task><Opcode>0</Opcode><Keywords>0x8010000000000000</Keywords><TimeCreated SystemTime=\"${TS}\"/><EventRecordID>$1</EventRecordID><Correlation/><Execution ProcessID=\"516\" ThreadID=\"3240\"/><Channel>Security</Channel><Computer>$8</Computer><Security/></System><EventData><Data Name=\"SubjectUserSid\">S-1-5-18</Data><Data Name=\"SubjectUserName\">${8%%.*}\$</Data><Data Name=\"SubjectDomainName\">${DOMAIN}</Data><Data Name=\"SubjectLogonId\">0x3e7</Data><Data Name=\"TargetUserSid\">S-1-0-0</Data><Data Name=\"TargetUserName\">$2</Data><Data Name=\"TargetDomainName\">${DOMAIN}</Data><Data Name=\"Status\">$6</Data><Data Name=\"FailureReason\">${FAILREASON}</Data><Data Name=\"SubStatus\">$7</Data><Data Name=\"LogonType\">$5</Data><Data Name=\"LogonProcessName\">NtLmSsp</Data><Data Name=\"AuthenticationPackageName\">NTLM</Data><Data Name=\"WorkstationName\">$3</Data><Data Name=\"TransmittedServices\">-</Data><Data Name=\"LmPackageName\">NTLM V2</Data><Data Name=\"KeyLength\">0</Data><Data Name=\"ProcessId\">0x1bc</Data><Data Name=\"ProcessName\">C:\\Windows\\System32\\winlogon.exe</Data><Data Name=\"IpAddress\">$4</Data><Data Name=\"IpPort\">$((40000 + $1 % 20000))</Data></EventData></Event>"
}

newproc() { # $1=recordid $2=user $3=newprocname $4=cmdline $5=parentproc $6=elevation $7=computer
  printf '%s\n' "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System>${PROVIDER}<EventID>4688</EventID><Version>2</Version><Level>0</Level><Task>13312</Task><Opcode>0</Opcode><Keywords>0x8020000000000000</Keywords><TimeCreated SystemTime=\"${TS}\"/><EventRecordID>$1</EventRecordID><Correlation/><Execution ProcessID=\"4\" ThreadID=\"84\"/><Channel>Security</Channel><Computer>$7</Computer><Security/></System><EventData><Data Name=\"SubjectUserSid\">S-1-5-21-3623811015-3361044348-30300820-1013</Data><Data Name=\"SubjectUserName\">$2</Data><Data Name=\"SubjectDomainName\">${DOMAIN}</Data><Data Name=\"SubjectLogonId\">0x$(printf '%x' $((0x500000 + $1 * 131)))</Data><Data Name=\"NewProcessId\">0x$(printf '%x' $((0x1000 + $1 * 17)))</Data><Data Name=\"NewProcessName\">$3</Data><Data Name=\"TokenElevationType\">$6</Data><Data Name=\"ProcessId\">0x$(printf '%x' $((0x800 + $1 * 7)))</Data><Data Name=\"CommandLine\">$4</Data><Data Name=\"TargetUserSid\">S-1-0-0</Data><Data Name=\"TargetUserName\">-</Data><Data Name=\"TargetDomainName\">-</Data><Data Name=\"TargetLogonId\">0x0</Data><Data Name=\"ParentProcessName\">$5</Data><Data Name=\"MandatoryLabel\">S-1-16-8192</Data></EventData></Event>"
}

lockout() { # $1=recordid $2=user $3=callercomputer $4=computer
  printf '%s\n' "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System>${PROVIDER}<EventID>4740</EventID><Version>0</Version><Level>0</Level><Task>13824</Task><Opcode>0</Opcode><Keywords>0x8020000000000000</Keywords><TimeCreated SystemTime=\"${TS}\"/><EventRecordID>$1</EventRecordID><Correlation/><Execution ProcessID=\"744\" ThreadID=\"4160\"/><Channel>Security</Channel><Computer>$4</Computer><Security/></System><EventData><Data Name=\"TargetUserName\">$2</Data><Data Name=\"TargetDomainName\">$3</Data><Data Name=\"TargetSid\">S-1-5-21-3623811015-3361044348-30300820-1188</Data><Data Name=\"SubjectUserSid\">S-1-5-18</Data><Data Name=\"SubjectUserName\">${4%%.*}\$</Data><Data Name=\"SubjectDomainName\">${DOMAIN}</Data><Data Name=\"SubjectLogonId\">0x3e7</Data></EventData></Event>"
}

{
  # --- 4624 successful logons: the benign bulk ---
  rid=100000
  for ((i = 0; i < NOISE_COUNT; i++)); do
    rid=$((rid + 1 + i % 5))
    u=${users[$((i % ${#users[@]}))]}
    h=${hosts[$((i % ${#hosts[@]}))]}
    ip="192.168.$((1 + i % 3)).${subnet[$((i % ${#subnet[@]}))]}"
    lt=${ltypes[$((i % ${#ltypes[@]}))]}
    lp=${lprocs[$((i % ${#lprocs[@]}))]}
    logon "$rid" "$u" "$h" "$ip" "$lt" "$lp" "DC01.contoso.local"
  done

  # --- 4625 failed logons: password spray against bfranklin from one host ---
  failed 200011 bfranklin WKS-014 203.0.113.77 3 0xc000006d 0xc000006a DC01.contoso.local
  failed 200012 bfranklin WKS-014 203.0.113.77 3 0xc000006d 0xc000006a DC01.contoso.local
  failed 200013 bfranklin WKS-014 203.0.113.77 3 0xc000006d 0xc000006a DC01.contoso.local
  failed 200014 bfranklin WKS-014 203.0.113.77 3 0xc000006d 0xc000006a DC01.contoso.local
  failed 200015 administrator WKS-014 203.0.113.77 3 0xc000006d 0xc000006a DC01.contoso.local
  failed 200016 svc_sql SQL01 10.0.4.19 5 0xc0000064 0xc0000064 SQL01.contoso.local

  # --- 4688 process creation: benign desktop activity plus recon on WKS-014 ---
  newproc 300021 jsmith 'C:\Program Files\Google\Chrome\Application\chrome.exe' 'chrome.exe --profile-directory=Default' 'C:\Windows\explorer.exe' 'TokenElevationTypeLimited (3)' WKS-001.contoso.local
  newproc 300022 mgarcia 'C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE' 'OUTLOOK.EXE /recycle' 'C:\Windows\explorer.exe' 'TokenElevationTypeLimited (3)' WKS-002.contoso.local
  newproc 300023 tnguyen 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'powershell.exe -NoProfile -File C:\Scripts\Get-DiskReport.ps1' 'C:\Windows\System32\taskeng.exe' 'TokenElevationTypeDefault (1)' WKS-007.contoso.local
  newproc 300024 bfranklin 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'powershell.exe -nop -w hidden -enc SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAAuAFcAZQBiAEMAbABpAGUAbgB0ACkA' 'C:\Windows\System32\cmd.exe' 'TokenElevationTypeFull (2)' WKS-014.contoso.local
  newproc 300025 bfranklin 'C:\Windows\System32\whoami.exe' 'whoami.exe /groups' 'C:\Windows\System32\cmd.exe' 'TokenElevationTypeFull (2)' WKS-014.contoso.local
  newproc 300026 bfranklin 'C:\Windows\System32\rundll32.exe' 'rundll32.exe C:\Users\Public\update.dll,DllRegisterServer' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'TokenElevationTypeFull (2)' WKS-014.contoso.local

  # --- 4740 account lockouts ---
  lockout 400031 bfranklin WKS-014 DC01.contoso.local
  lockout 400032 administrator WKS-014 DC01.contoso.local
  lockout 400033 svc_sql SQL01 DC01.contoso.local
} > "$OUT"

total=$(wc -l < "$OUT" | tr -d ' ')
echo "wrote $OUT"
echo "  4624 successful logon : $(grep -c '<EventID>4624</EventID>' "$OUT")"
echo "  4625 failed logon     : $(grep -c '<EventID>4625</EventID>' "$OUT")"
echo "  4688 process creation : $(grep -c '<EventID>4688</EventID>' "$OUT")"
echo "  4740 account lockout  : $(grep -c '<EventID>4740</EventID>' "$OUT")"
echo "  total lines           : $total"

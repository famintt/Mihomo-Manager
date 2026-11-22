#!/usr/bin/env python3
"""MM-18: static checks for the command-builder contract."""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "interface" / "index.html").read_text(encoding="utf-8")
WORKER = (ROOT / "interface" / "worker.js").read_text(encoding="utf-8")
checks = 0

def check(condition: bool, message: str) -> None:
    global checks
    if not condition:
        print(f"not ok - {message}", file=sys.stderr)
        raise SystemExit(1)
    checks += 1
    print(f"ok {checks} - {message}")

check("e && !e.disabled" in HTML and "return e ? String(e.value).trim()" not in HTML,
      "disabled form values are excluded from generated commands")
check("if (val('ws-mode') === 'cdn') numEnv('wspt', 'wspt', envs);" in HTML,
      "WS listener is emitted only while its mode is enabled")
for field, port in (("vl_sni", "vlrt"), ("vx_sni", "vxpt"), ("tu_sni", "tupt"),
                    ("any_sni", "anypt"), ("hy_sni", "hypt")):
    check(f"if (val('{port}')) strEnv('{field}'" in HTML,
          f"{field} is gated by its protocol port")
check("if (val('argo') === 'vlpt') { strEnv('agn', 'agn', envs); strEnv('agk', 'agk', envs); }" in HTML,
      "fixed Argo credentials are gated by Argo enablement")
check("['argo_cdn_host', 'argo_cdn_port', 'argo_pt', 'agn', 'agk']" in HTML,
      "disabled Argo values are cleared from command generation")
check("tuic_zero_rtt" not in HTML and "TUIC 0-RTT" not in HTML,
      "dead TUIC 0-RTT control and setting are removed")
check("留空使用内置加密 DNS" in HTML and "off/none/0/false/disabled" in HTML,
      "DNS description matches default and disable semantics")
for key in ("sub_read_token", "sub_report_token", "sub_machine"):
    check(key in HTML, f"subscription generator supports {key}")
check("['sub_token'" not in HTML and 'id="sub-token"' not in HTML,
      "legacy shared sub_token is never generated")
check("validateSubConfig(subDomain, readToken, reportToken, machine)" in HTML and
      "readToken === reportToken" in HTML and "parsed.protocol !== 'https:'" in HTML,
      "Worker config validates HTTPS and separate credentials")
check(r"!/^https:\/\/[^/?#\\\s]+\/?$/.test(domain)" in HTML,
      "Worker domain rejects path, query, fragments, and extra slashes")
check("^[a-z0-9][a-z0-9_-]{0,63}$" in HTML,
      "machine slug uses contracted lowercase grammar")
anchors = re.findall(r'<a\b[^>]*\btarget=["\']_blank["\'][^>]*>', HTML, flags=re.I)
rels = [re.search(r'\brel=["\']([^"\']*)["\']', a, re.I) for a in anchors]
check(bool(anchors) and all(m and "noopener" in m.group(1).split() and "noreferrer" in m.group(1).split() for m in rels),
      "every target=_blank link has noopener noreferrer")
version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
expected_worker_html = HTML.replace("__VERSION__", version)
embedded_html = json.JSONDecoder().raw_decode(WORKER.split('const HTML = ', 1)[1])[0]
check(expected_worker_html == embedded_html,
      "generated Worker embeds the current interface source")
scripts = re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", HTML, flags=re.S | re.I)
syntax = subprocess.run(["node", "--check"], input="\n".join(scripts), capture_output=True, text=True)
check(bool(scripts) and syntax.returncode == 0,
      "embedded interface JavaScript passes Node syntax validation")
check("sub_read_token" in WORKER and "noopener noreferrer" in WORKER,
      "generated Worker contains updated subscription and link safeguards")
check("ws-cert-validation" in HTML and "certStatus.textContent = certError" in HTML,
      "custom certificate mode reports missing certificate or private key")
validator = re.search(r"  function validateSubConfig\(.*?\n  \}", HTML, flags=re.S)
check(validator is not None, "subscription validator function is present")
if validator:
    good = ["https://sub.example.com", "ReadToken_0123456789abcdef", "ReportToken_0123456789abcdef", "hk_1"]
    cases = [
        [good, False],
        [["http://sub.example.com", *good[1:]], True],
        [["https://sub.example.com/path", *good[1:]], True],
        [["https://user@sub.example.com", *good[1:]], True],
        [[good[0], "short", *good[2:]], True],
        [[good[0], good[1], good[1], good[3]], True],
        [[good[0], good[1], good[2], "BadSlug"], True],
        [["https://127.0.0.1", *good[1:]], True],
    ]
    script = validator.group(0) + "\nconst cases = " + json.dumps(cases) + ";\nfor (const [args, invalid] of cases) { const error = validateSubConfig(...args); if (Boolean(error) !== invalid) { console.error(JSON.stringify({args,error,invalid})); process.exit(1); } }"
    run = subprocess.run(["node", "-e", script], capture_output=True, text=True)
    check(run.returncode == 0, "subscription validator accepts/rejects runtime contract cases")
print(f"1..{checks}")

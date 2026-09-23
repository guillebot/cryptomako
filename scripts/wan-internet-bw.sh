#!/bin/bash
# Query LiberTik wan-internet in/out via Grafana on 10.1.1.8 (docker net), SA token file.
set -euo pipefail
TOKEN_FILE="${GRAFANA_SA_TOKEN_FILE:-/Users/guille/dev/cryptomako/.grafana-sa-token}"
TOKEN=$(cat "$TOKEN_FILE")
ssh -o BatchMode=yes guille@10.1.1.8 bash -s <<EOF
TOKEN='$TOKEN'
CIP=\$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' grafana | awk '{print \$1}')
P="http://\$CIP:3000/api/datasources/proxy/uid/ee0curg6egwsgf"
q(){ curl -sS -m 15 -H "Authorization: Bearer \$TOKEN" --get "\$P/api/v1/query" --data-urlencode "query=\$1"; }
python3 - "\$TOKEN" <<'PY'
import json,subprocess,sys
token=open('/dev/stdin').read() if False else None
PY
qin=\$(curl -sS -m 15 -H "Authorization: Bearer \$TOKEN" --get "\$P/api/v1/query" --data-urlencode 'query=rate(mktxp_interface_rx_byte_total{routerboard_name="LiberTik",name="wan-internet"}[2m])*8')
qout=\$(curl -sS -m 15 -H "Authorization: Bearer \$TOKEN" --get "\$P/api/v1/query" --data-urlencode 'query=rate(mktxp_interface_tx_byte_total{routerboard_name="LiberTik",name="wan-internet"}[2m])*8')
python3 -c "import json,sys
def mbps(s):
 d=json.loads(s); r=(d.get('data') or {}).get('result') or []
 return float(r[0]['value'][1])/1e6 if r else float('nan')
print(f'wan-internet in  {mbps(sys.argv[1]):.3f} Mbps')
print(f'wan-internet out {mbps(sys.argv[2]):.3f} Mbps')" "\$qin" "\$qout"
EOF

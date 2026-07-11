import json

with open('/tmp/vulns2.json') as f:
    vulns = json.load(f)

pkgs = {}
for v in vulns:
    p = v['package']
    if p not in pkgs:
        pkgs[p] = {'count': 0, 'severities': {}}
    pkgs[p]['count'] += 1
    s = v['severity']
    pkgs[p]['severities'][s] = pkgs[p]['severities'].get(s, 0) + 1

for p in sorted(pkgs, key=lambda x: -pkgs[x]['count']):
    print(f"{p}: {pkgs[p]['count']} vulns - {pkgs[p]['severities']}")

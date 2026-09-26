"""Sets explicit Openverse search terms / result picks for images whose default search was poor.
Usage: python3 set-search.py id=term[@pick] ..."""
import json
import os
import sys

p = os.path.join(os.path.dirname(__file__), 'dataset.json')
d = json.load(open(p))
for arg in sys.argv[1:]:
    k, v = arg.split('=', 1)
    term, _, pick = v.partition('@')
    for i in d['images']:
        if i['id'] == k:
            if term:
                i['search'] = term
            if pick:
                i['pick'] = int(pick)
json.dump(d, open(p, 'w'), indent=2)

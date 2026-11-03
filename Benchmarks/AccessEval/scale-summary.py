import json,sys,statistics as st
rows=[json.loads(l) for l in open(sys.argv[1])]
def pct(v,p):
    v=sorted(v); return v[min(len(v)-1,int(round(p/100*(len(v)-1))))]
kinds=['list','search','getMetadata','getTranscript']
cold={k:[] for k in kinds}
for r in rows:
    if r['label'].startswith('cold'):
        for k in kinds: cold[k]+=r[k]
warm=[r for r in rows if r['label']=='warm'][0]
print(f"meetings {warm['meetings']}; peak footprint MiB: cold max {max(r['peakFootprintMiB'] for r in rows if r['label'].startswith('cold')):.0f}, warm {warm['peakFootprintMiB']:.0f}; store open p50 {st.median([r['openMs'] for r in rows]):.1f} ms")
allc=sum(cold.values(),[]); allw=sum((warm[k][1:] for k in kinds),[])
print("| operation | cold n | cold p50 | cold p95 | warm n | warm p50 | warm p95 |\n|---|---|---|---|---|---|---|")
for k in kinds:
    w=warm[k][1:]
    print(f"| {k} | {len(cold[k])} | {pct(cold[k],50):.1f} | {pct(cold[k],95):.1f} | {len(w)} | {pct(w,50):.1f} | {pct(w,95):.1f} |")
print(f"| all | {len(allc)} | {pct(allc,50):.1f} | {pct(allc,95):.1f} | {len(allw)} | {pct(allw,50):.1f} | {pct(allw,95):.1f} |")
print(f"max cold {max(allc):.1f} ms, max warm {max(allw):.1f} ms")

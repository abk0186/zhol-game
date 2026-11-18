import json,re,sys
sys.path.insert(0,'.')
import cities_src as S
d=json.load(open('/workspace/zhol-game/wiki/raw.json'))
STOP=set('город города городе рядом самый самая самые около после потом сейчас здесь центр центра очень много большой большие старые старинный старинные новый вокруг набережная реки озеро области области'.split())
for k,c in S.C.items():
  o=d[k]; blob=' '.join([o.get('ru_ext',''),o.get('ru_wt',''),o.get('en_ext',''),o.get('en_wt',''),o.get('kk_ext',''),o.get('kk_wt','')])
  B=re.sub(r'[\s\u00a0]+',' ',blob); BL=B.lower()
  texts=c['hist'][0]+list(c['sights'][0])+[c['fun'][0]]+[c['found'][0] or '']+c['hist'][2]+[c['fun'][2]]
  miss=[]
  for t in texts:
    for n in re.findall(r'\d{3,4}',t):
      if n not in B: miss.append('NUM '+n)
  for s in c['sights'][0]:
    ws=[w for w in re.findall(r'[А-ЯЁа-яё\-]{5,}',s) if w.lower() not in STOP]
    ok=[w for w in ws if w.lower()[:5] in BL]
    if ws and len(ok)<max(1,len(ws)//2): miss.append('SIGHT '+s)
  if miss: print(k,miss)

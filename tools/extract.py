import re,sys,json
def literals(src):
    out=[];i=0;n=len(src)
    def tmpl(i):
        # src[i]=='`' ; returns (text_with_markers, end_index)
        buf='';i+=1
        while i<n:
            c=src[i]
            if c=='\\': buf+=src[i:i+2]; i+=2; continue
            if c=='`': return buf,i+1
            if c=='$' and src[i+1:i+2]=='{':
                depth=1;j=i+2
                inner_start=j
                while j<n and depth:
                    cj=src[j]
                    if cj in '\'"':
                        q=cj;j+=1
                        while j<n and src[j]!=q:
                            if src[j]=='\\': j+=1
                            j+=1
                        out.append(('s',src[inner_start:j]));
                    elif cj=='`':
                        t,j2=tmpl(j); out.append(('t',t)); j=j2; continue
                    elif cj=='{': depth+=1
                    elif cj=='}': depth-=1
                    j+=1
                inner=src[i+2:j-1]
                # nested string literals in expression
                for m in re.finditer(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"",inner):
                    out.append(('s',m.group(1) if m.group(1) is not None else m.group(2)))
                buf+='⟨X⟩'; i=j; continue
            buf+=c;i+=1
        return buf,i
    while i<n:
        c=src[i]
        if src.startswith('//',i) and (i==0 or src[i-1] in ' \n;{}('): j=src.find('\n',i); i=n if j<0 else j; continue
        if src.startswith('/*',i): j=src.find('*/',i); i=j+2; continue
        if c in '\'"':
            q=c;j=i+1
            while j<n and src[j]!=q and src[j]!='\n':
                if src[j]=='\\': j+=1
                j+=1
            out.append(('s',src[i+1:j])); i=j+1; continue
        if c=='`':
            t,i=tmpl(i); out.append(('t',t)); continue
        i+=1
    return out
frags=set()
for f in sys.argv[1:]:
    src=open(f).read()
    if f.endswith('.html'):
        src=re.sub(r'<script.*?</script>|<style.*?</style>','',src,flags=re.S)
        for a in re.findall(r'(?:placeholder|title|aria-label)="([^"]*)"',src): frags.add(a.strip())
        for p in re.split(r'<[^>]+>',src): frags.add(p.strip())
        continue
    for k,t in literals(src):
        for a in re.findall(r'(?:placeholder|title|aria-label)="([^"]*)"',t): frags.add(a.strip())
        for p in re.split(r'<[^>]*>',t): frags.add(p.strip())
frags=sorted(x for x in frags if re.search('[А-Яа-яЁё]',x))
json.dump(frags,open('/tmp/frags.json','w'),ensure_ascii=False,indent=0)
print(len(frags), sum(len(x) for x in frags))

import json,re,collections
out={}
for lvl in ['a1','a2','b1']:
    cat='';rows=[]
    for ln in open(f'{lvl}.txt',encoding='utf8'):
        ln=ln.rstrip('\n')
        if not ln.strip(): continue
        if ln.startswith('#'): cat=ln[1:].strip(); continue
        f=ln.split('|'); f+=['']*(5-len(f))
        en,hint,ru,kk,ex=[x.strip() for x in f[:5]]
        if kk and kk.lower() in ru.lower(): kk=''  # заимствования (автобус, билет…) не учим как казахские слова
        rows.append([en,hint,ru,kk,ex,cat])
    ens=collections.Counter(r[0] for r in rows); rus=collections.Counter(r[2] for r in rows)
    assert all(v==1 for v in ens.values()), [k for k,v in ens.items() if v>1]
    assert all(v==1 for v in rus.values()), [k for k,v in rus.items() if v>1]
    kks=collections.Counter(r[3] for r in rows if r[3]); assert all(v==1 for v in kks.values()), [k for k,v in kks.items() if v>1]
    out[lvl]=rows; print(lvl,len(rows),'kk',sum(1 for r in rows if r[3]),'ex',sum(1 for r in rows if r[4]))
js='// 📘 English в дороге — словарь по уровням (a1: 9–11 лет, a2: 12–14, b1: 15–16).\n// Формат: [en, подсказка произношения, перевод ru, слово по-казахски (только где точно; без заимствований вроде «автобус»), пример (a2/b1), тема]. id слова = уровень + ":" + en.\n// Генерируется из tools/*.txt (tools/gen.py); серверная копия ответов — таблица zhol.words (sql/13_english.sql).\nwindow.ZHOL_WORDS = '+json.dumps(out,ensure_ascii=False,separators=(',',':')).replace('],[','],\n[')+';\n'
open('../words.js','w',encoding='utf8').write(js)
q=lambda s:"'"+s.replace("'","''")+"'"
vals=[f"({q(l+':'+r[0])},{q(l)},{q(r[5])},{q(r[0])},{q(r[2])},{q(r[3])})" for l,rows in out.items() for r in rows]
open('../sql/13_words_data.sql','w',encoding='utf8').write('-- 13b: словарь English в дороге (генерируется tools/gen.py из tools/*.txt)\ninsert into zhol.words(id,lvl,cat,en,ru,kk) values\n'+',\n'.join(vals)+'\non conflict (id) do update set lvl=excluded.lvl, cat=excluded.cat, en=excluded.en, ru=excluded.ru, kk=excluded.kk;\n')

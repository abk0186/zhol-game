# Собирает site/i18n.js (словарь + названия городов + движок) и site/cities_info.js
import json,sys,os,re
sys.path.insert(0,os.path.dirname(__file__))
import i18n_dict as I, cities_src as S
RU = {"AKT":"Актобе","AKU":"Актау","ALA":"Алматы","ARL":"Аральск","AST":"Астана","ATY":"Атырау","AYA":"Аягоз","BAL":"Балхаш","BUR":"Бурабай","EKI":"Экибастуз","KAR":"Караганда","KAS":"Каскелен","KOK":"Кокшетау","KON":"Конаев","KOR":"Кордай","KOS":"Костанай","KZO":"Кызылорда","MER":"Мерке","PAV":"Павлодар","PET":"Петропавловск","SEM":"Семей","SHU":"Шу","SHY":"Шымкент","TAL":"Талгар","TAR":"Тараз","TEM":"Темиртау","TLD":"Талдыкорган","TUR":"Туркестан","URA":"Уральск","USK":"Усть-Каменогорск","UZY":"Узынагаш","ZHE":"Жезказган"}
EN_SHORT = {'USK':'Oskemen','URA':'Oral'}
names = {k:{'ru':RU[k],'kk':S.C[k]['kk'],'en':EN_SHORT.get(k,S.C[k]['en'])} for k in RU}
D = list(I.D)
TR = [('пешком','жаяу','on foot','🚶'),('на велосипеде','велосипедпен','by bike','🚲'),('на коне','атпен','on horseback','🐎'),('на машине','көлікпен','by car','🚕'),('на автобусе','автобуспен','by bus','🚌'),('на поезде','пойызбен','by train','🚆'),('на самолёте','ұшақпен','by plane','✈️')]
for ru,kk,en,ic in TR:
    D.append((f'Продолжить {ru} {ic} или сменить транспорт?', f'{kk.capitalize()} {ic} жалғастырасың ба, әлде көлікті ауыстырасың ба?', f'Continue {en} {ic} or switch transport?'))
for ru,kk,en,ic in TR:
    D.append((f'Тараз → Кордай {ic} 120 км', f'{{c0}} {ic} 120 км', f'{{c0}} {ic} 120 km'))
LV=[('A1 · начальный','A1 · бастапқы','A1 · beginner'),('A2 · базовый','A2 · базалық','A2 · elementary'),('B1 · средний','B1 · орта','B1 · intermediate'),('B2 · выше среднего','B2 · ортадан жоғары','B2 · upper-intermediate')]
for w,n in [('слово',1),('слова',2),('слов',5)]:
    en_w='word' if n==1 else 'words'
    for ru,kk,en in LV:
        D.append((f'📘 English: выучено {n} {w} ({ru})', f'📘 English: {n} сөз үйренілді ({kk})', f'📘 English: {n} {en_w} learned ({en})'))
    D.append((f'🇰🇿 Қазақша: выучено {n} {w}', f'🇰🇿 Қазақша: {n} сөз үйренілді', f'🇰🇿 Kazakh: {n} {en_w} learned'))
seen=set(); out=[]
for r in D:
    assert len(r)==3, r
    if r[0] in seen: continue
    seen.add(r[0]); out.append(list(r))
eng=open(os.path.join(os.path.dirname(__file__),'i18n_engine.js')).read()
js = ('// Жол — языки интерфейса: Русский / Қазақша / English. Сгенерировано tools/build_i18n.py — правьте tools/i18n_dict.py.\n'
      'window.ZHOL_CITY_NAMES = ' + json.dumps(names, ensure_ascii=False) + ';\n'
      'window.ZHOL_I18N_DICT = ' + json.dumps(out, ensure_ascii=False, indent=0) + ';\n' + eng)
open(os.path.join(os.path.dirname(__file__),'..','i18n.js'),'w').write(js)
# ---- cities_info.js
info={}
for k,c in S.C.items():
    r=S.REG[c['reg']]
    pop=c['pop']
    info[k]=dict(n=names[k], reg=dict(ru=r[0],kk=r[1],en=r[2]),
        f=dict(ru=c['found'][0],kk=c['found'][1],en=c['found'][2]) if c['found'][0] else None,
        pop=pop[0], popY=pop[1], popSrc=pop[2], area=c['area'],
        h=dict(ru=c['hist'][0],kk=c['hist'][1],en=c['hist'][2]), s=dict(ru=c['sights'][0],kk=c['sights'][1],en=c['sights'][2]),
        fun=dict(ru=c['fun'][0],kk=c['fun'][1],en=c['fun'][2]), t=dict(ru=c['teaser'][0],kk=c['teaser'][1],en=c['teaser'][2]),
        src=[ (lambda l,t: f'https://{l}.wikipedia.org/wiki/'+t.replace(' ','_'))(*x.split(':',1)) for x in c['src']] + (['https://stat.gov.kz/ru/industries/social-statistics/demography/'] if 'Бюро' in pop[2] else []))
js2=('// Жол — справки о городах (RU/KK/EN). Только реальные данные: Википедия (ru/kk/en) и Бюро национальной статистики РК (stat.gov.kz).\n'
     '// Проверено 18.11.2026. Сгенерировано tools/build_i18n.py из tools/cities_src.py. popY — год данных о населении; area — км² (null = источники расходятся/нет данных).\n'
     'window.ZHOL_CITIES = ' + json.dumps(info, ensure_ascii=False, indent=0) + ';\n')
open(os.path.join(os.path.dirname(__file__),'..','cities_info.js'),'w').write(js2)
print('dict',len(out),'cities',len(info))

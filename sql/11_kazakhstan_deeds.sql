-- 11: вся карта Казахстана + «Добрые дела» (звёзды ⭐ за реальные дела открывают новые края)
alter table zhol.nodes add column if not exists region text;
alter table zhol.players add column if not exists stars int not null default 0;
alter table zhol.players add column if not exists unlocked text[] not null default '{}';

-- новые города (координаты OSM Nominatim), км по дорогам — OSRM; ж/д только где точно ходят поезда; рейсы — прямые из Алматы/Астаны (Википедия, ноябрь 2026)
insert into zhol.nodes(id,name,kind,airport,souvenir,region) values
  ('SHY','Шымкент','city',true,'Открытка с дендропарком Шымкента','south'),
  ('TUR','Туркестан','city',true,'Открытка с мавзолеем Ходжи Ахмеда Ясави','south'),
  ('TLD','Талдыкорган','city',true,'Открытка «Жетісу — край семи рек»','zhetysu'),
  ('TEM','Темиртау','town',false,'Значок металлурга','saryarka'),
  ('ZHE','Жезказган','city',true,'Камешек медной руды','saryarka'),
  ('KOK','Кокшетау','city',true,'Открытка с озером Копа','kokshe'),
  ('BUR','Бурабай','town',false,'Открытка со скалой Окжетпес','kokshe'),
  ('PET','Петропавловск','city',true,'Открытка с рекой Есиль (Ишим)','kokshe'),
  ('KZO','Кызылорда','city',true,'Мешочек кызылординского риса','syr'),
  ('EKI','Экибастуз','town',false,'Кусочек угля-сувенир','ertis'),
  ('PAV','Павлодар','city',true,'Открытка с рекой Иртыш','ertis'),
  ('SEM','Семей','city',true,'Книжка стихов Абая','east'),
  ('AYA','Аягоз','town',false,'Открытка с мавзолеем Козы Корпеш — Баян сулу','east'),
  ('USK','Усть-Каменогорск','city',true,'Баночка алтайского мёда','east'),
  ('ARL','Аральск','town',false,'Открытка с кораблями Аральского моря','aral'),
  ('KOS','Костанай','city',true,'Колосок пшеницы','tobyl'),
  ('AKT','Актобе','city',true,'Открытка с мечетью Нур Гасыр','west'),
  ('URA','Уральск','city',true,'Открытка с рекой Жайык (Урал)','west'),
  ('ATY','Атырау','city',true,'Открытка с мостом между Европой и Азией','caspian'),
  ('AKU','Актау','city',true,'Ракушка с Каспийского моря','caspian')
on conflict (id) do nothing;
insert into zhol.edges(a,b,km,mode,rail) values
  ('TAR','SHY',180,'road',true),
  ('SHY','TUR',163,'road',true),
  ('TUR','KZO',291,'road',true),
  ('KZO','ARL',457,'road',true),
  ('ARL','AKT',620,'road',true),
  ('AKT','URA',478,'road',false),
  ('URA','ATY',505,'road',false),
  ('AKT','ATY',618,'road',false),
  ('ATY','AKU',901,'road',true),
  ('AST','KOS',708,'road',false),
  ('AST','KOK',314,'road',true),
  ('KOK','BUR',83,'road',false),
  ('KOK','PET',187,'road',true),
  ('AST','EKI',321,'road',true),
  ('EKI','PAV',143,'road',true),
  ('PAV','SEM',335,'road',false),
  ('SEM','USK',218,'road',false),
  ('SEM','AYA',354,'road',true),
  ('AYA','TLD',509,'road',false),
  ('TLD','KON',192,'road',false),
  ('KAR','TEM',34,'road',false),
  ('KAR','ZHE',531,'road',true),
  ('ZHE','KZO',429,'road',false),
  ('AYA','USK',305,'road',false),
  ('BAL','AYA',512,'road',false),
  ('ALA','AKU',2073,'air',false),
  ('ALA','AKT',1691,'air',false),
  ('ALA','ATY',2000,'air',false),
  ('ALA','URA',2111,'air',false),
  ('ALA','USK',863,'air',false),
  ('ALA','KZO',931,'air',false),
  ('ALA','SHY',609,'air',false),
  ('ALA','KOS',1480,'air',false),
  ('ALA','SEM',836,'air',false),
  ('ALA','PAV',1006,'air',false),
  ('ALA','TUR',702,'air',false),
  ('ALA','ZHE',880,'air',false),
  ('ALA','KOK',1248,'air',false),
  ('ALA','PET',1411,'air',false),
  ('AST','AKU',1732,'air',false),
  ('AST','AKT',1010,'air',false),
  ('AST','ATY',1486,'air',false),
  ('AST','URA',1397,'air',false),
  ('AST','USK',799,'air',false),
  ('AST','SHY',989,'air',false),
  ('AST','KOS',583,'air',false),
  ('AST','KZO',826,'air',false),
  ('AST','SEM',622,'air',false),
  ('AST','TUR',902,'air',false),
  ('AST','PAV',399,'air',false),
  ('AST','ZHE',457,'air',false),
  ('AST','PET',445,'air',false),
  ('AST','TLD',850,'air',false)
on conflict do nothing;

update zhol.settings set value = value || jsonb_build_object('deeds', $j${"max_day":10,
 "cats":{"grade":{"e":"📚","t":"Хорошая оценка в школе","p5":3,"p4":1,"cap":9},
         "read":{"e":"📖","t":"Прочитал(а) страницы","per":10,"cap":5},
         "book":{"e":"📕","t":"Дочитал(а) книгу","p":5,"cap":5},
         "home":{"e":"🧹","t":"Помог(ла) дома: уборка и дела","p":2,"cap":4},
         "good":{"e":"🤝","t":"Доброе дело для людей","p":3,"cap":6},
         "sport":{"e":"🏃","t":"Спорт / тренировка","p":2,"cap":2}},
 "regions":[{"id":"south","n":"Оңтүстік — Юг","e":"🕌","need":10},
            {"id":"zhetysu","n":"Жетісу","e":"🏞️","need":20},
            {"id":"saryarka","n":"Сарыарқа","e":"⛏️","need":30},
            {"id":"kokshe","n":"Көкше — Бурабай","e":"🌲","need":45},
            {"id":"syr","n":"Сыр бойы","e":"🌾","need":60},
            {"id":"ertis","n":"Ертіс","e":"🌊","need":80},
            {"id":"east","n":"Шығыс — Восток","e":"⛰️","need":100},
            {"id":"aral","n":"Арал","e":"⚓","need":120},
            {"id":"tobyl","n":"Тобыл — Костанай","e":"🌻","need":140},
            {"id":"west","n":"Батыс — Запад","e":"🐫","need":165},
            {"id":"caspian","n":"Каспий","e":"🐚","need":200}]}$j$::jsonb) where key='config' and not (value ? 'deeds');

-- город открыт для ребёнка: базовый (region is null) или край уже открыт
create or replace function zhol._open(p text, node text) returns boolean language sql stable as $$
  select coalesce((select n.region is null or n.region = any(pl.unlocked) from zhol.nodes n, zhol.players pl where n.id=node and pl.id=p), false) $$;

-- открыть края, на которые хватает звёзд; системное сообщение в чат
create or replace function zhol._unlock_check(p text) returns text[] language plpgsql as $$
declare r zhol.players; reg jsonb; newr text[] := '{}'; names text;
begin
  select * into r from zhol.players where id=p for update;
  if r.id is null then return newr; end if;
  for reg in select x from jsonb_array_elements(coalesce(zhol._cfg()->'deeds'->'regions','[]'::jsonb)) x loop
    if not ((reg->>'id') = any(r.unlocked)) and r.stars >= coalesce((reg->>'need')::int, 1000000) then newr := newr || (reg->>'id'); end if;
  end loop;
  if coalesce(array_length(newr,1),0) > 0 then
    update zhol.players set unlocked = unlocked || newr, updated_at=now() where id=p;
    select string_agg(n.name, ', ' order by n.name) into names from zhol.nodes n where n.region = any(newr);
    insert into zhol.log(player,kind,data) values(p,'unlock',jsonb_build_object('regions',to_jsonb(newr),'by','stars','stars',r.stars));
    if names is not null then
      insert into zhol.chat(kind,author_id,text,hidden) values('system',p,'🔓 '||r.name||' открыл(а) '||names||' — за добрые дела! ⭐',r.hidden);
    end if;
  end if;
  return newr;
end $$;

-- вручную (администратор)
create or replace function zhol._unlock_region(p text, region text, by text) returns text language plpgsql as $$
#variable_conflict use_variable
declare r zhol.players; names text;
begin
  select * into r from zhol.players where id=p for update;
  if r.id is null then return 'no_player'; end if;
  if not exists(select 1 from jsonb_array_elements(coalesce(zhol._cfg()->'deeds'->'regions','[]'::jsonb)) x where x->>'id'=region) then return 'bad_region'; end if;
  if region = any(r.unlocked) then return 'ok'; end if;
  update zhol.players set unlocked = unlocked || region, updated_at=now() where id=p;
  select string_agg(n.name, ', ' order by n.name) into names from zhol.nodes n where n.region = region;
  insert into zhol.log(player,kind,data) values(p,'unlock',jsonb_build_object('regions',jsonb_build_array(region),'by',by));
  if names is not null then insert into zhol.chat(kind,author_id,text,hidden) values('system',p,'🔓 '||r.name||' открыл(а) '||names||'! ⭐',r.hidden); end if;
  return 'ok';
end $$;
revoke all on function zhol._open(text,text), zhol._unlock_check(text), zhol._unlock_region(text,text,text) from public, anon, authenticated;

-- ребёнок отмечает доброе дело → запрос родителям (kind='deed'); звёзды — только после подтверждения
create or replace function public.zhol_deed(p text, code text, cat text, amount int default null, comment text default '') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); D jsonb := coalesce(zhol._cfg()->'deeds','{}'::jsonb); C jsonb; pts int; used int; n int; cap int; cm text := btrim(coalesce(comment,''));
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  perform 1 from zhol.players where id=p for update;
  C := D->'cats'->cat;
  if C is null then return jsonb_build_object('ok',false,'error','bad_cat'); end if;
  if length(cm) > 200 then return jsonb_build_object('ok',false,'error','too_long'); end if;
  select count(*) into n from zhol.requests where player=p and kind='deed' and (created_at at time zone 'Asia/Almaty')::date=zhol._day();
  if n >= coalesce((D->>'max_day')::int,10) then return jsonb_build_object('ok',false,'error','deed_limit'); end if;
  if (select count(*) from zhol.requests where player=p and kind='deed' and status='pending') >= 15 then return jsonb_build_object('ok',false,'error','too_many'); end if;
  if cat='grade' then
    if amount is null or amount not in (4,5) then return jsonb_build_object('ok',false,'error','bad_amount'); end if;
    pts := case when amount=5 then coalesce((C->>'p5')::int,3) else coalesce((C->>'p4')::int,1) end;
  elsif cat='read' then
    if amount is null or amount<5 or amount>300 then return jsonb_build_object('ok',false,'error','bad_amount'); end if;
    pts := greatest(1, floor(amount / greatest(1,coalesce((C->>'per')::numeric,10)))::int);
  else
    amount := null; pts := coalesce((C->>'p')::int,1);
  end if;
  cap := (C->>'cap')::int;
  if cap is not null then
    select coalesce(sum((item->>'points')::int),0) into used from zhol.requests
      where player=p and kind='deed' and item->>'cat'=cat and status<>'rejected' and (created_at at time zone 'Asia/Almaty')::date=zhol._day();
    pts := least(pts, cap - used);
  end if;
  if pts <= 0 then return jsonb_build_object('ok',false,'error','deed_cap'); end if;
  insert into zhol.requests(player,kind,item,cost) values(p,'deed',
    jsonb_build_object('cat',cat,'e',C->>'e','title',C->>'t','amount',amount,'points',pts,'comment',nullif(cm,'')),0);
  insert into zhol.log(player,kind,data) values(p,'deed',jsonb_build_object('cat',cat,'points',pts));
  return public.zhol_login(p, code);
end $$;
revoke all on function public.zhol_deed(text,text,text,int,text) from public;
grant execute on function public.zhol_deed(text,text,text,int,text) to anon, authenticated;

CREATE OR REPLACE FUNCTION zhol._pstate(p text)
 RETURNS jsonb LANGUAGE sql STABLE AS $function$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),'fuel',round(zhol._fuel(pl),2),'stars',stars,'unlocked',unlocked,
    'deeds_today',coalesce((select jsonb_object_agg(c,s) from (select item->>'cat' c, sum((item->>'points')::int) s from zhol.requests where player=p and kind='deed' and status<>'rejected' and (created_at at time zone 'Asia/Almaty')::date=zhol._day() group by 1) x),'{}'::jsonb),
    'deeds_n_today',(select count(*) from zhol.requests where player=p and kind='deed' and (created_at at time zone 'Asia/Almaty')::date=zhol._day()),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players pl where id=p $function$;

create or replace function zhol._decide(rid bigint, status text, note text, by text) returns text language plpgsql as $$
#variable_conflict use_variable
declare rq zhol.requests; km numeric; d zhol.daily; nt int;
begin
  select * into rq from zhol.requests where id=rid for update;
  if rq.id is null then return 'no_request'; end if;
  if status='done' and rq.status in ('approved','pending') then
    if rq.status='pending' and rq.kind<>'reward' then return 'approve_first'; end if;
    update zhol.requests set status='done', decided_at=now(), decided_by=by where id=rq.id;
  elsif rq.status<>'pending' then return 'already';
  elsif status='approved' then
    update zhol.requests set status = case when rq.kind='reward' then 'approved' else 'done' end, decided_at=now(), note=nullif(note,''), decided_by=by where id=rq.id;
    if rq.kind='quest' then perform zhol._award(rq.player, (rq.item->>'reward')::int, 'quest', false); end if;
    if rq.kind='deed' then
      update zhol.players set stars=stars+greatest(0,coalesce((rq.item->>'points')::int,0)), updated_at=now() where id=rq.player;
      perform zhol._unlock_check(rq.player);
    end if;
    if rq.kind='steps' then
      km := (rq.item->>'km')::numeric; d := zhol._daily(rq.player);
      update zhol.daily dd set km=dd.km+km where dd.player=rq.player and dd.day=d.day;
      update zhol.players set km_total=km_total+km, tok_frac=tok_frac+km/coalesce((zhol._cfg()->>'km_per_token')::numeric,5) where id=rq.player returning floor(tok_frac) into nt;
      if nt>0 then update zhol.players set tok_frac=tok_frac-nt where id=rq.player; perform zhol._award(rq.player, nt, 'steps', true); end if;
      perform zhol._check_ach(rq.player);
    end if;
  elsif status='rejected' then
    update zhol.requests set status='rejected', decided_at=now(), note=nullif(note,''), decided_by=by where id=rq.id;
    if rq.kind='reward' then update zhol.players set tokens=tokens+rq.cost where id=rq.player; end if;
  else return 'bad_status';
  end if;
  insert into zhol.log(player,kind,data) values(rq.player,'decide',jsonb_build_object('id',rq.id,'status',status,'by',by));
  return 'ok';
end $$;

revoke all on function zhol._decide(bigint,text,text,text) from public, anon, authenticated;

create or replace function public.zhol_start_trip(p text, code text, transport text, path text[]) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); r zhol.players; legs numeric[] := '{}'; total numeric := 0; k numeric; i int; n int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if transport not in ('walk','bike','horse','car','bus','train','plane') then return jsonb_build_object('ok',false,'error','bad_transport'); end if;
  n := coalesce(array_length(path,1),0);
  if n<2 or n>12 or path[1]<>r.location then return jsonb_build_object('ok',false,'error','bad_path'); end if;
  if (select count(distinct x) from unnest(path) x) <> n then return jsonb_build_object('ok',false,'error','bad_path'); end if;
  if transport='plane' then
    if n<>2 then return jsonb_build_object('ok',false,'error','bad_path'); end if;
    if r.tickets<1 then return jsonb_build_object('ok',false,'error','no_ticket'); end if;
  end if;
  for i in 1..n-1 loop
    k := zhol._edge(path[i], path[i+1], case when transport='plane' then 'air' else 'road' end);
    if k is null then return jsonb_build_object('ok',false,'error','bad_path'); end if;
    legs := legs || k; total := total + k;
  end loop;
  if exists(select 1 from unnest(path) x where not zhol._open(p, x)) then return jsonb_build_object('ok',false,'error','locked_city'); end if;
  perform zhol._race_forfeit(p); perform zhol._race_cancel_pending(p);
  if transport='train' and not zhol._path_rail(path) then return jsonb_build_object('ok',false,'error','no_rail'); end if;
  if transport='plane' then update zhol.players set tickets=tickets-1 where id=p; end if;
  update zhol.players set trip=jsonb_build_object('path',to_jsonb(path),'legs',to_jsonb(legs),'total',total,'done',0,'transport',transport,
      'started',now(),'last',now(),'collected','[]'::jsonb),
    transports = case when transport = any(transports) then transports else transports||transport end, updated_at=now() where id=p;
  insert into zhol.log(player,kind,data) values(p,'start',jsonb_build_object('path',path,'transport',transport,'total',total));
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;


create or replace function public.zhol_challenge_create(p text, code text, opponent text, path text[], transport text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); a zhol.players; b zhol.players; legs numeric[]; total numeric;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  perform zhol._race_expire();
  if transport not in ('walk','bike','horse','car') then return jsonb_build_object('ok',false,'error','bad_transport'); end if;
  select * into a from zhol.players where id=p;
  select * into b from zhol.players where id=opponent;
  if b.id is null or b.id=p or b.hidden<>a.hidden then return jsonb_build_object('ok',false,'error','no_player'); end if;
  if a.trip is not null or b.trip is not null then return jsonb_build_object('ok',false,'error','on_trip'); end if;
  if a.location<>b.location then return jsonb_build_object('ok',false,'error','not_same_place'); end if;
  if exists(select 1 from zhol.challenges c where c.status in ('pending','active') and (c.challenger in (p,opponent) or c.opponent in (p,opponent))) then
    return jsonb_build_object('ok',false,'error','has_challenge'); end if;
  if path[1]<>a.location then return jsonb_build_object('ok',false,'error','bad_path'); end if;
  legs := zhol._path_legs(path,'road');
  if legs is null then return jsonb_build_object('ok',false,'error','bad_path'); end if;
  if exists(select 1 from unnest(path) x where not zhol._open(p, x) or not zhol._open(opponent, x)) then return jsonb_build_object('ok',false,'error','locked_city'); end if;
  select sum(x) into total from unnest(legs) x;
  insert into zhol.challenges(challenger,opponent,path,legs,total,transport) values(p,opponent,path,legs,total,transport);
  insert into zhol.log(player,kind,data) values(p,'race_create',jsonb_build_object('opponent',opponent,'path',path,'transport',transport));
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.zhol_request(p text, code text, kind text, payload jsonb) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; item jsonb; cost int; small int; q zhol.quests; steps int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if (select count(*) from zhol.requests where player=p and status='pending' and kind<>'deed') >= 10 then return jsonb_build_object('ok',false,'error','too_many'); end if;
  if kind='reward' then
    select x into item from zhol.settings s, jsonb_array_elements(s.value) x where s.key='catalog' and x->>'id' = payload->>'id';
    if item is null then return jsonb_build_object('ok',false,'error','no_item'); end if;
    cost := (item->>'cost')::int;
    if r.tokens < cost then return jsonb_build_object('ok',false,'error','not_enough'); end if;
    small := coalesce((zhol._cfg()->>'small_reward_max')::int,30);
    update zhol.players set tokens=tokens-cost where id=p;
    insert into zhol.requests(player,kind,item,cost,status) values(p,'reward',item,cost, case when cost<=small and not coalesce((item->>'big')::boolean,false) then 'approved' else 'pending' end);
  elsif kind='quest' then
    select * into q from zhol.quests where id=(payload->>'id')::bigint and active and (player is null or player=p);
    if q.id is null then return jsonb_build_object('ok',false,'error','no_quest'); end if;
    if exists(select 1 from zhol.requests rr where rr.player=p and rr.kind='quest' and (rr.item->>'id')::bigint=q.id and rr.status in ('pending','approved','done')) then return jsonb_build_object('ok',false,'error','already'); end if;
    insert into zhol.requests(player,kind,item,cost) values(p,'quest',to_jsonb(q),0);
  elsif kind='steps' then
    steps := least(greatest(coalesce((payload->>'steps')::int,0),0),30000);
    if steps<100 then return jsonb_build_object('ok',false,'error','bad_steps'); end if;
    if exists(select 1 from zhol.requests rr where rr.player=p and rr.kind='steps' and (rr.created_at at time zone 'Asia/Almaty')::date=zhol._day()) then return jsonb_build_object('ok',false,'error','already'); end if;
    insert into zhol.requests(player,kind,item,cost) values(p,'steps',jsonb_build_object('steps',steps,'km',round(steps*0.0007,2)),0);
  else return jsonb_build_object('ok',false,'error','bad_kind'); end if;
  return public.zhol_login(p, code);
end $$;


CREATE OR REPLACE FUNCTION public.zhol_admin(pin text, action text, payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zhol', 'public'
AS $function$
#variable_conflict use_variable
declare st text := zhol._pin(pin); rq zhol.requests; v text; km numeric; d zhol.daily; nt int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  if action='set_pin' then
    v := payload->>'new_pin';
    if v !~ '^[0-9]{4,8}$' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.settings set value = value || jsonb_build_object('hash',extensions.crypt(v, extensions.gen_salt('bf'))) where key='pin';
  elsif action='set_code' then
    v := payload->>'code';
    if v !~ '^[0-9]{4}$' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.players set code_hash=extensions.crypt(v, extensions.gen_salt('bf')), fails=0, locked_until=null where id=payload->>'player';
  elsif action='set_family_code' then
    v := payload->>'code';
    if v !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.families set code_hash=extensions.crypt(v, extensions.gen_salt('bf')), fails=0, locked_until=null where id=payload->>'family';
  elsif action='set_config' then
    update zhol.settings set value = value || (payload->'config') where key='config';
    perform zhol._unlock_check(x.id) from zhol.players x;
  elsif action='unlock' then
    v := zhol._unlock_region(payload->>'player', payload->>'region', 'admin');
    if v<>'ok' then return jsonb_build_object('ok',false,'error',v); end if;
  elsif action='stars' then
    update zhol.players set stars=greatest(0,stars+coalesce((payload->>'n')::int,0)) where id=payload->>'player';
    insert into zhol.log(player,kind,data) values(payload->>'player','admin_stars',payload);
    perform zhol._unlock_check(payload->>'player');
  elsif action='set_catalog' then
    if jsonb_typeof(payload->'catalog')<>'array' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.settings set value = payload->'catalog' where key='catalog';
  elsif action='add_quest' then
    insert into zhol.quests(title,reward,player) values(payload->>'title', least(greatest(coalesce((payload->>'reward')::int,10),1),500), nullif(payload->>'player',''));
  elsif action='end_quest' then
    update zhol.quests set active=false where id=(payload->>'id')::bigint;
  elsif action='decide' then
    v := zhol._decide((payload->>'id')::bigint, payload->>'status', payload->>'note', 'admin');
    if v<>'ok' then return jsonb_build_object('ok',false,'error',v); end if;
  elsif action='adjust' then
    update zhol.players set tokens=greatest(0,tokens+coalesce((payload->>'tokens')::int,0)), tickets=greatest(0,tickets+coalesce((payload->>'tickets')::int,0)) where id=payload->>'player';
    insert into zhol.log(player,kind,data) values(payload->>'player','admin_adjust',payload);
  elsif action='reset_trip' then
    update zhol.challenges set status='cancelled', cancelled_by='admin', finished_at=now() where status in ('pending','active') and winner is null and (challenger=payload->>'player' or opponent=payload->>'player');
    update zhol.players set trip=null where id=payload->>'player';
  elsif action='move_home' then
    update zhol.challenges set status='cancelled', cancelled_by='admin', finished_at=now() where status in ('pending','active') and winner is null and (challenger=payload->>'player' or opponent=payload->>'player');
    update zhol.players set trip=null, location=home where id=payload->>'player';
  elsif action<>'overview' then return jsonb_build_object('ok',false,'error','bad_action');
  end if;
  return jsonb_build_object('ok',true,
    'players',(select jsonb_agg(zhol._pstate(id) || jsonb_build_object('locked',locked_until>now()) order by sort) from zhol.players where not hidden),
    'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by id desc),'[]') from (select * from zhol.requests order by (status='pending') desc, id desc limit 100) r),
    'quests',(select coalesce(jsonb_agg(to_jsonb(q) order by id desc),'[]') from zhol.quests q where active),
    'config',zhol._cfg(), 'families',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'locked',locked_until>now()) order by sort),'[]') from zhol.families), 'catalog',(select value from zhol.settings where key='catalog'),
    'suspicious',(select coalesce(jsonb_agg(to_jsonb(l) order by id desc),'[]') from (select * from zhol.log where kind in ('too_fast','clamped') order by id desc limit 20) l));
end $function$
;


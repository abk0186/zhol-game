create extension if not exists pgcrypto with schema extensions;
create schema if not exists zhol;
revoke all on schema zhol from public, anon, authenticated;

create table zhol.nodes(id text primary key, name text not null, kind text not null default 'town', airport boolean not null default false, souvenir text);
create table zhol.edges(a text references zhol.nodes, b text references zhol.nodes, km numeric not null, mode text not null default 'road', primary key(a,b,mode));
create table zhol.players(
  id text primary key, name text not null, age int not null, league text not null, home text references zhol.nodes,
  school text, avatar text, color text, sort int default 0,
  code_hash text not null, fails int not null default 0, locked_until timestamptz,
  location text references zhol.nodes, trip jsonb,
  km_total numeric not null default 0, ticket_km numeric not null default 0,
  tokens int not null default 0, tok_frac numeric not null default 0, tickets int not null default 0,
  visited text[] not null default '{}', gifts text[] not null default '{}', delivered text[] not null default '{}',
  gifts_total int not null default 0, achievements text[] not null default '{}', transports text[] not null default '{}',
  quiz_ok int not null default 0, longest_trip numeric not null default 0, updated_at timestamptz not null default now());
create table zhol.daily(player text references zhol.players on delete cascade, day date, km numeric not null default 0, tokens int not null default 0, taps int not null default 0, counters jsonb not null default '{}', primary key(player,day));
create table zhol.log(id bigserial primary key, player text, kind text, data jsonb, at timestamptz not null default now());
create table zhol.settings(key text primary key, value jsonb not null);
create table zhol.requests(id bigserial primary key, player text references zhol.players on delete cascade, kind text not null, item jsonb, cost int not null default 0, status text not null default 'pending', note text, created_at timestamptz not null default now(), decided_at timestamptz);
create table zhol.quests(id bigserial primary key, title text not null, reward int not null default 10, player text, active boolean not null default true, created_at timestamptz not null default now());
alter table zhol.nodes enable row level security; alter table zhol.edges enable row level security; alter table zhol.players enable row level security;
alter table zhol.daily enable row level security; alter table zhol.log enable row level security; alter table zhol.settings enable row level security;
alter table zhol.requests enable row level security; alter table zhol.quests enable row level security;

-- helpers
create or replace function zhol._day() returns date language sql stable as $$ select (now() at time zone 'Asia/Almaty')::date $$;
create or replace function zhol._mult(age int) returns numeric language sql immutable as $$ select case when age<=11 then 1.6 when age<=14 then 1.25 else 1.0 end $$;
create or replace function zhol._cfg() returns jsonb language sql stable as $$ select value from zhol.settings where key='config' $$;
create or replace function zhol._edge(x text, y text, m text) returns numeric language sql stable as $$
  select km from zhol.edges where mode=m and ((a=x and b=y) or (a=y and b=x)) limit 1 $$;

create or replace function zhol._auth(p text, code text) returns text language plpgsql as $$
declare r zhol.players;
begin
  select * into r from zhol.players where id=p for update;
  if not found then return 'no_player'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if code is null or extensions.crypt(code, r.code_hash) <> r.code_hash then
    if r.fails+1 >= 5 then update zhol.players set fails=0, locked_until=now()+interval '5 minutes' where id=p;
    else update zhol.players set fails=r.fails+1 where id=p; end if;
    return 'bad_code';
  end if;
  if r.fails>0 then update zhol.players set fails=0 where id=p; end if;
  return 'ok';
end $$;
revoke all on function zhol._auth(text,text) from public, anon, authenticated;

create or replace function zhol._daily(p text) returns zhol.daily language plpgsql as $$
declare d zhol.daily;
begin
  insert into zhol.daily(player,day) values(p, zhol._day()) on conflict do nothing;
  select * into d from zhol.daily where player=p and day=zhol._day() for update;
  return d;
end $$;

create or replace function zhol._award(p text, n int, reason text, capped boolean) returns int language plpgsql as $$
declare d zhol.daily; cap int := coalesce((zhol._cfg()->>'daily_token_cap')::int, 80); give int := greatest(n,0);
begin
  if give=0 then return 0; end if;
  d := zhol._daily(p);
  if capped then give := least(give, greatest(0, cap - d.tokens)); end if;
  if give>0 then
    update zhol.players set tokens=tokens+give, updated_at=now() where id=p;
    if capped then update zhol.daily set tokens=tokens+give where player=p and day=d.day; end if;
    insert into zhol.log(player,kind,data) values(p,'tokens',jsonb_build_object('n',give,'reason',reason,'capped',capped));
  end if;
  return give;
end $$;

create or replace function zhol._ach(p text, a text) returns boolean language plpgsql as $$
begin
  if exists(select 1 from zhol.players where id=p and a = any(achievements)) then return false; end if;
  update zhol.players set achievements = achievements || a where id=p;
  perform zhol._award(p, 10, 'ach:'||a, false);
  insert into zhol.log(player,kind,data) values(p,'ach',jsonb_build_object('a',a));
  return true;
end $$;

create or replace function zhol._check_ach(p text) returns void language plpgsql as $$
declare r zhol.players;
begin
  select * into r from zhol.players where id=p;
  if r.km_total>=100 then perform zhol._ach(p,'km100'); end if;
  if r.km_total>=1000 then perform zhol._ach(p,'km1000'); end if;
  if r.km_total>=5000 then perform zhol._ach(p,'km5000'); end if;
  if r.longest_trip>=1000 then perform zhol._ach(p,'far'); end if;
  if r.visited @> array['ALA','AST','TAR','KOR'] then perform zhol._ach(p,'big4'); end if;
  if coalesce(array_length(r.delivered,1),0)>=5 then perform zhol._ach(p,'gifts5'); end if;
  if r.quiz_ok>=10 then perform zhol._ach(p,'quiz10'); end if;
  if r.transports @> array['walk','bike','horse','car','bus','plane'] then perform zhol._ach(p,'all_trans'); end if;
end $$;

create or replace function zhol._pstate(p text) returns jsonb language sql stable as $$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players where id=p $$;

-- PUBLIC API
create or replace function public.zhol_public_state() returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select jsonb_build_object(
    'players',(select jsonb_agg(zhol._pstate(id) order by sort) from zhol.players),
    'nodes',(select jsonb_agg(to_jsonb(n)) from zhol.nodes n),
    'edges',(select jsonb_agg(to_jsonb(e)) from zhol.edges e),
    'config',(select value - 'secret' from zhol.settings where key='config'),
    'catalog',(select value from zhol.settings where key='catalog'),
    'quests',(select coalesce(jsonb_agg(to_jsonb(q) order by id desc),'[]') from zhol.quests q where active),
    'family',jsonb_build_object(
      'total_km',(select round(sum(km_total),1) from zhol.players),
      'week_km',(select coalesce(round(sum(km),1),0) from zhol.daily where day>=date_trunc('week',zhol._day())::date),
      'kordai_today',(select coalesce(jsonb_agg(distinct player),'[]') from zhol.log where kind='arrive' and data->>'to'='KOR' and (at at time zone 'Asia/Almaty')::date=zhol._day()),
      'all_visited',(select coalesce(jsonb_agg(distinct v),'[]') from zhol.players, unnest(visited) v),
      'family_ach',(select value from zhol.settings where key='family_ach')),
    'today',zhol._day(), 'now', now()) $$;

create or replace function public.zhol_login(p text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code);
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  return jsonb_build_object('ok',true,'me',zhol._pstate(p),
    'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by id desc),'[]') from (select * from zhol.requests where player=p order by id desc limit 30) r));
end $$;

create or replace function public.zhol_start_trip(p text, code text, transport text, path text[]) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); r zhol.players; legs numeric[] := '{}'; total numeric := 0; k numeric; i int; n int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if transport not in ('walk','bike','horse','car','bus','plane') then return jsonb_build_object('ok',false,'error','bad_transport'); end if;
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
  if transport='plane' then update zhol.players set tickets=tickets-1 where id=p; end if;
  update zhol.players set trip=jsonb_build_object('path',to_jsonb(path),'legs',to_jsonb(legs),'total',total,'done',0,'transport',transport,
      'started',now(),'last',now(),'collected','[]'::jsonb),
    transports = case when transport = any(transports) then transports else transports||transport end, updated_at=now() where id=p;
  insert into zhol.log(player,kind,data) values(p,'start',jsonb_build_object('path',path,'transport',transport,'total',total));
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_cancel_trip(p text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code);
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  update zhol.players set trip=null where id=p;
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_progress(p text, code text, km numeric, taps int, dur_ms int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; tr text; dur numeric; m numeric; maxkm numeric; kmv numeric;
  cfg jsonb := zhol._cfg(); d zhol.daily; done numeric; total numeric; path text[]; legs numeric[]; collected jsonb;
  factor numeric; nt int; cum numeric := 0; i int; node text; sv text; g text; events jsonb := '[]'; got int; arrived boolean := false;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  t := r.trip;
  if t is null then return jsonb_build_object('ok',false,'error','no_trip','me',zhol._pstate(p)); end if;
  tr := t->>'transport'; taps := greatest(coalesce(taps,0),0);
  dur := least(greatest(coalesce(dur_ms,0),0), 60000, extract(epoch from now()-(t->>'last')::timestamptz)*1000 + 1500);
  if taps > ceil(12*dur/1000.0)+2 then
    insert into zhol.log(player,kind,data) values(p,'too_fast',jsonb_build_object('taps',taps,'dur',dur,'km',km));
    update zhol.players set trip = jsonb_set(t,'{last}',to_jsonb(now())) where id=p;
    return jsonb_build_object('ok',false,'error','too_fast','me',zhol._pstate(p));
  end if;
  m := zhol._mult(r.age);
  maxkm := 1.1 * case tr when 'walk' then taps*0.10*m when 'bike' then taps*0.20*m when 'horse' then taps*0.6*m
    when 'car' then dur/1000*1.5*m when 'bus' then dur/1000*0.8 when 'plane' then dur/1000*60 end;
  kmv := least(greatest(coalesce(km,0),0), maxkm);
  if coalesce(km,0) > maxkm*1.5 + 0.5 then insert into zhol.log(player,kind,data) values(p,'clamped',jsonb_build_object('km',km,'max',maxkm,'tr',tr)); end if;
  d := zhol._daily(p);
  kmv := least(kmv, greatest(0, coalesce((cfg->>'daily_km_cap')::numeric,2500) - d.km));
  done := (t->>'done')::numeric; total := (t->>'total')::numeric;
  kmv := least(kmv, total-done); done := done + kmv;
  select array_agg(x) into path from jsonb_array_elements_text(t->'path') x;
  select array_agg(x::numeric) into legs from jsonb_array_elements_text(t->'legs') x;
  collected := coalesce(t->'collected','[]');
  update zhol.daily dd set km=dd.km+kmv, taps=dd.taps+zhol_progress.taps where dd.player=p and dd.day=d.day;
  update zhol.players set km_total=km_total+kmv, ticket_km = ticket_km + case when tr='plane' then 0 else kmv end where id=p;
  -- tokens for km
  factor := case when tr='plane' then 0.2 when tr='horse' and 'KOR'=any(path) then 1.5 else 1 end;
  update zhol.players set tok_frac = tok_frac + kmv/coalesce((cfg->>'km_per_token')::numeric,5)*factor where id=p returning floor(tok_frac) into nt;
  if nt>0 then update zhol.players set tok_frac=tok_frac-nt where id=p; perform zhol._award(p, nt, 'km', true); end if;
  -- tickets
  nt := null;
  update zhol.players set tickets = tickets + floor(ticket_km / coalesce((cfg->>'ticket_every_km')::numeric,250))::int,
    ticket_km = ticket_km - floor(ticket_km / coalesce((cfg->>'ticket_every_km')::numeric,250))*coalesce((cfg->>'ticket_every_km')::numeric,250)
    where id=p and ticket_km >= coalesce((cfg->>'ticket_every_km')::numeric,250) returning tickets into nt;
  if nt is not null then events := events || jsonb_build_object('type','ticket'); end if;
  -- nodes passed
  for i in 1..array_length(path,1) loop
    if i>1 then cum := cum + legs[i-1]; end if;
    exit when cum > done + 0.0001;
    node := path[i];
    if i>1 and not collected ? node then
      collected := collected || to_jsonb(node);
      select * into r from zhol.players where id=p;
      if not node = any(r.visited) then
        update zhol.players set visited = visited || node where id=p;
        got := zhol._award(p, 5, 'new_city', true);
        events := events || jsonb_build_object('type','new_city','node',node,'tokens',got);
      end if;
      select souvenir into sv from zhol.nodes where id=node;
      if sv is not null then
        update zhol.players set gifts = gifts || node where id=p and not node = any(gifts);
        events := events || jsonb_build_object('type','souvenir','node',node);
      end if;
      if node='KOR' then
        select * into r from zhol.players where id=p;
        foreach g in array r.gifts loop
          if g = any(r.delivered) then got := zhol._award(p,3,'gift_repeat',true);
          else update zhol.players set delivered = delivered || g where id=p; got := zhol._award(p,10,'gift_new',false); end if;
          events := events || jsonb_build_object('type','delivered','node',g,'tokens',got);
        end loop;
        update zhol.players set gifts_total = gifts_total + coalesce(array_length(gifts,1),0), gifts='{}' where id=p;
      end if;
    end if;
  end loop;
  if done >= total - 0.0001 then
    arrived := true;
    node := path[array_length(path,1)];
    update zhol.players set location=node, trip=null, longest_trip=greatest(longest_trip,total), updated_at=now() where id=p;
    insert into zhol.log(player,kind,data) values(p,'arrive',jsonb_build_object('to',node,'from',path[1],'transport',tr,'km',total));
    perform zhol._ach(p,'first_trip');
    if node='KOR' then perform zhol._ach(p,'first_kor'); end if;
    if tr='horse' and node='KOR' then perform zhol._ach(p,'horse_kor'); end if;
    if (path[1]='ALA' and node='AST') or (path[1]='AST' and node='ALA') then perform zhol._ach(p,'ala_ast'); end if;
    events := events || jsonb_build_object('type','arrive','node',node);
  else
    update zhol.players set trip = jsonb_set(jsonb_set(jsonb_set(t,'{done}',to_jsonb(round(done,3))),'{last}',to_jsonb(now())),'{collected}',collected), updated_at=now() where id=p;
  end if;
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'km',round(kmv,3),'arrived',arrived,'events',events,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_bonus(p text, code text, kind text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); d zhol.daily; lim int; n int; c int; got int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  lim := case kind when 'quiz' then 10 when 'gift' then 10 when 'bus' then 20 else 0 end;
  n := case kind when 'quiz' then 2 else 1 end;
  if lim=0 then return jsonb_build_object('ok',false,'error','bad_kind'); end if;
  d := zhol._daily(p); c := coalesce((d.counters->>kind)::int,0);
  if c>=lim then return jsonb_build_object('ok',true,'tokens',0,'limit',true,'me',zhol._pstate(p)); end if;
  update zhol.daily set counters = jsonb_set(counters, array[kind], to_jsonb(c+1)) where player=p and day=d.day;
  if kind='quiz' then update zhol.players set quiz_ok=quiz_ok+1 where id=p; end if;
  got := zhol._award(p, n, 'bonus:'||kind, true);
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'tokens',got,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_request(p text, code text, kind text, payload jsonb) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; item jsonb; cost int; small int; q zhol.quests; steps int;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if (select count(*) from zhol.requests where player=p and status='pending') >= 10 then return jsonb_build_object('ok',false,'error','too_many'); end if;
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

-- ADMIN
create or replace function zhol._pin(pin text) returns text language plpgsql as $$
declare s jsonb;
begin
  select value into s from zhol.settings where key='pin' for update;
  if (s->>'until') is not null and (s->>'until')::timestamptz > now() then return 'locked'; end if;
  if pin is null or extensions.crypt(pin, s->>'hash') <> s->>'hash' then
    update zhol.settings set value = case when coalesce((s->>'fails')::int,0)+1>=5
      then s || jsonb_build_object('fails',0,'until',now()+interval '10 minutes') else s || jsonb_build_object('fails',coalesce((s->>'fails')::int,0)+1) end where key='pin';
    return 'bad_pin';
  end if;
  update zhol.settings set value = s || jsonb_build_object('fails',0,'until',null) where key='pin';
  return 'ok';
end $$;

create or replace function public.zhol_admin(pin text, action text, payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
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
  elsif action='set_catalog' then
    if jsonb_typeof(payload->'catalog')<>'array' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.settings set value = payload->'catalog' where key='catalog';
  elsif action='add_quest' then
    insert into zhol.quests(title,reward,player) values(payload->>'title', least(greatest(coalesce((payload->>'reward')::int,10),1),500), nullif(payload->>'player',''));
  elsif action='end_quest' then
    update zhol.quests set active=false where id=(payload->>'id')::bigint;
  elsif action='decide' then
    select * into rq from zhol.requests where id=(payload->>'id')::bigint for update;
    if rq.id is null then return jsonb_build_object('ok',false,'error','no_request'); end if;
    if (payload->>'status')='done' and rq.status in ('approved','pending') then
      if rq.status='pending' and rq.kind<>'reward' then return jsonb_build_object('ok',false,'error','approve_first'); end if;
      update zhol.requests set status='done', decided_at=now() where id=rq.id;
    elsif rq.status<>'pending' then return jsonb_build_object('ok',false,'error','already');
    elsif (payload->>'status')='approved' then
      update zhol.requests set status = case when rq.kind='reward' then 'approved' else 'done' end, decided_at=now(), note=payload->>'note' where id=rq.id;
      if rq.kind='quest' then perform zhol._award(rq.player, (rq.item->>'reward')::int, 'quest', false); end if;
      if rq.kind='steps' then
        km := (rq.item->>'km')::numeric; d := zhol._daily(rq.player);
        update zhol.daily dd set km=dd.km+(rq.item->>'km')::numeric where dd.player=rq.player and dd.day=d.day;
        update zhol.players set km_total=km_total+km, tok_frac=tok_frac+km/coalesce((zhol._cfg()->>'km_per_token')::numeric,5) where id=rq.player returning floor(tok_frac) into nt;
        if nt>0 then update zhol.players set tok_frac=tok_frac-nt where id=rq.player; perform zhol._award(rq.player, nt, 'steps', true); end if;
        perform zhol._check_ach(rq.player);
      end if;
    elsif (payload->>'status')='rejected' then
      update zhol.requests set status='rejected', decided_at=now(), note=payload->>'note' where id=rq.id;
      if rq.kind='reward' then update zhol.players set tokens=tokens+rq.cost where id=rq.player; end if;
    end if;
  elsif action='adjust' then
    update zhol.players set tokens=greatest(0,tokens+coalesce((payload->>'tokens')::int,0)), tickets=greatest(0,tickets+coalesce((payload->>'tickets')::int,0)) where id=payload->>'player';
    insert into zhol.log(player,kind,data) values(payload->>'player','admin_adjust',payload);
  elsif action='reset_trip' then
    update zhol.players set trip=null where id=payload->>'player';
  elsif action='move_home' then
    update zhol.players set trip=null, location=home where id=payload->>'player';
  elsif action<>'overview' then return jsonb_build_object('ok',false,'error','bad_action');
  end if;
  return jsonb_build_object('ok',true,
    'players',(select jsonb_agg(zhol._pstate(id) || jsonb_build_object('locked',locked_until>now()) order by sort) from zhol.players),
    'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by id desc),'[]') from (select * from zhol.requests order by (status='pending') desc, id desc limit 100) r),
    'quests',(select coalesce(jsonb_agg(to_jsonb(q) order by id desc),'[]') from zhol.quests q where active),
    'config',zhol._cfg(), 'families',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'locked',locked_until>now()) order by sort),'[]') from zhol.families), 'catalog',(select value from zhol.settings where key='catalog'),
    'suspicious',(select coalesce(jsonb_agg(to_jsonb(l) order by id desc),'[]') from (select * from zhol.log where kind in ('too_fast','clamped') order by id desc limit 20) l));
end $$;
 then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.families set code_hash=extensions.crypt(v, extensions.gen_salt('bf')), fails=0, locked_until=null where id=payload->>'family';
  elsif action='set_config' then
    update zhol.settings set value = value || (payload->'config') where key='config';
  elsif action='set_catalog' then
    if jsonb_typeof(payload->'catalog')<>'array' then return jsonb_build_object('ok',false,'error','bad_format'); end if;
    update zhol.settings set value = payload->'catalog' where key='catalog';
  elsif action='add_quest' then
    insert into zhol.quests(title,reward,player) values(payload->>'title', least(greatest(coalesce((payload->>'reward')::int,10),1),500), nullif(payload->>'player',''));
  elsif action='end_quest' then
    update zhol.quests set active=false where id=(payload->>'id')::bigint;
  elsif action='decide' then
    select * into rq from zhol.requests where id=(payload->>'id')::bigint for update;
    if rq.id is null then return jsonb_build_object('ok',false,'error','no_request'); end if;
    if (payload->>'status')='done' and rq.status in ('approved','pending') then
      if rq.status='pending' and rq.kind<>'reward' then return jsonb_build_object('ok',false,'error','approve_first'); end if;
      update zhol.requests set status='done', decided_at=now() where id=rq.id;
    elsif rq.status<>'pending' then return jsonb_build_object('ok',false,'error','already');
    elsif (payload->>'status')='approved' then
      update zhol.requests set status = case when rq.kind='reward' then 'approved' else 'done' end, decided_at=now(), note=payload->>'note' where id=rq.id;
      if rq.kind='quest' then perform zhol._award(rq.player, (rq.item->>'reward')::int, 'quest', false); end if;
      if rq.kind='steps' then
        km := (rq.item->>'km')::numeric; d := zhol._daily(rq.player);
        update zhol.daily dd set km=dd.km+(rq.item->>'km')::numeric where dd.player=rq.player and dd.day=d.day;
        update zhol.players set km_total=km_total+km, tok_frac=tok_frac+km/coalesce((zhol._cfg()->>'km_per_token')::numeric,5) where id=rq.player returning floor(tok_frac) into nt;
        if nt>0 then update zhol.players set tok_frac=tok_frac-nt where id=rq.player; perform zhol._award(rq.player, nt, 'steps', true); end if;
        perform zhol._check_ach(rq.player);
      end if;
    elsif (payload->>'status')='rejected' then
      update zhol.requests set status='rejected', decided_at=now(), note=payload->>'note' where id=rq.id;
      if rq.kind='reward' then update zhol.players set tokens=tokens+rq.cost where id=rq.player; end if;
    end if;
  elsif action='adjust' then
    update zhol.players set tokens=greatest(0,tokens+coalesce((payload->>'tokens')::int,0)), tickets=greatest(0,tickets+coalesce((payload->>'tickets')::int,0)) where id=payload->>'player';
    insert into zhol.log(player,kind,data) values(payload->>'player','admin_adjust',payload);
  elsif action='reset_trip' then
    update zhol.players set trip=null where id=payload->>'player';
  elsif action='move_home' then
    update zhol.players set trip=null, location=home where id=payload->>'player';
  elsif action<>'overview' then return jsonb_build_object('ok',false,'error','bad_action');
  end if;
  return jsonb_build_object('ok',true,
    'players',(select jsonb_agg(zhol._pstate(id) || jsonb_build_object('locked',locked_until>now()) order by sort) from zhol.players),
    'requests',(select coalesce(jsonb_agg(to_jsonb(r) order by id desc),'[]') from (select * from zhol.requests order by (status='pending') desc, id desc limit 100) r),
    'quests',(select coalesce(jsonb_agg(to_jsonb(q) order by id desc),'[]') from zhol.quests q where active),
    'config',zhol._cfg(), 'catalog',(select value from zhol.settings where key='catalog'),
    'suspicious',(select coalesce(jsonb_agg(to_jsonb(l) order by id desc),'[]') from (select * from zhol.log where kind in ('too_fast','clamped') order by id desc limit 20) l));
end $$;

revoke all on all functions in schema zhol from public, anon, authenticated;
revoke all on function public.zhol_public_state(), public.zhol_login(text,text), public.zhol_start_trip(text,text,text,text[]), public.zhol_cancel_trip(text,text),
  public.zhol_progress(text,text,numeric,int,int), public.zhol_bonus(text,text,text), public.zhol_request(text,text,text,jsonb), public.zhol_admin(text,text,jsonb) from public;
grant execute on function public.zhol_public_state(), public.zhol_login(text,text), public.zhol_start_trip(text,text,text,text[]), public.zhol_cancel_trip(text,text),
  public.zhol_progress(text,text,numeric,int,int), public.zhol_bonus(text,text,text), public.zhol_request(text,text,text,jsonb), public.zhol_admin(text,text,jsonb) to anon, authenticated;

alter table zhol.requests add column if not exists decided_by text;
alter table zhol.families add column if not exists hidden boolean not null default false;
create table if not exists zhol.chat(id bigserial primary key, kind text not null, author_id text, text text not null, hidden boolean not null default false, deleted boolean not null default false, created_at timestamptz not null default now());
alter table zhol.chat enable row level security;
revoke all on zhol.chat from anon, authenticated;
create index if not exists chat_author_idx on zhol.chat(kind, author_id, created_at);

-- общее решение по запросу: by = 'admin' или 'family:<id>'
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

create or replace function public.zhol_families() returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'all',f.all_kids,
    'kids',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'avatar',p.avatar) order by p.sort),'[]') from zhol.players p where (p.family=f.id or f.all_kids) and not p.hidden)) order by f.sort),'[]')
  from zhol.families f where not f.hidden $$;

-- родители решают запросы только своих детей («Все дети (Асет)» — всех)
create or replace function public.zhol_family_decide(f text, code text, id bigint, status text, note text default '') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._fauth(f, code); fam zhol.families; pl text; v text;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where zhol.families.id=f;
  select r.player into pl from zhol.requests r where r.id=zhol_family_decide.id;
  if pl is null or not exists(select 1 from zhol.players p where p.id=pl and (p.family=f or fam.all_kids) and (not p.hidden or fam.hidden)) then
    return jsonb_build_object('ok',false,'error','not_your_kid'); end if;
  v := zhol._decide(zhol_family_decide.id, status, note, 'family:'||f);
  if v<>'ok' then return jsonb_build_object('ok',false,'error',v); end if;
  return public.zhol_family_login(f, code);
end $$;
revoke all on function public.zhol_family_decide(text,text,bigint,text,text) from public;
grant execute on function public.zhol_family_decide(text,text,bigint,text,text) to anon, authenticated;

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
CREATE OR REPLACE FUNCTION public.zhol_family_login(f text, code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zhol', 'public'
AS $function$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  return jsonb_build_object('ok',true,
    'family',jsonb_build_object('id',fam.id,'name',fam.name,'all',fam.all_kids),
    'families',(select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort) from zhol.families where not all_kids and not hidden),
    'kids',(select coalesce(jsonb_agg(zhol._pstate(p.id) || jsonb_build_object('family',p.family) order by p.sort),'[]') from zhol.players p where (p.family=f or fam.all_kids) and (not p.hidden or fam.hidden)),
    'activity',(select coalesce(jsonb_agg(jsonb_build_object('player',l.player,'kind',l.kind,'data',l.data,'at',l.at) order by l.id desc),'[]')
       from (select * from zhol.log where kind in ('start','arrive','ach','switch') and player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or fam.hidden)) order by id desc limit 60) l),
    'requests',(select coalesce(jsonb_agg(to_jsonb(rq) order by (rq.status='pending') desc, (rq.status='approved') desc, rq.id desc),'[]') from (select * from zhol.requests where player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or fam.hidden)) order by (status in ('pending','approved')) desc, id desc limit 40) rq),
    'pending',(select count(*) from zhol.requests where status='pending' and player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or fam.hidden))),
    'pub', public.zhol_public_state(fam.hidden));
end $function$
;
create or replace function public.zhol_progress(p text, code text, km numeric, taps int, dur_ms int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; tr text; dur numeric; m numeric; maxkm numeric; kmv numeric;
  cfg jsonb := zhol._cfg(); d zhol.daily; done numeric; total numeric; path text[]; legs numeric[]; collected jsonb;
  factor numeric; nt int; cum numeric := 0; i int; node text; sv text; g text; events jsonb := '[]'; got int; arrived boolean := false; ch zhol.challenges; other text; origin text; f numeric;
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
  -- лошадь: не больше одного тапа на удар ритма (450 мс)
  if tr='horse' then taps := least(taps, ceil(dur/450.0)::int + 2); end if;
  maxkm := 1.1 * case tr when 'walk' then taps*0.10*m when 'bike' then taps*0.20*m when 'horse' then taps*0.6*m
    when 'car' then dur/1000*1.5*m when 'bus' then dur/1000*0.8 when 'train' then dur/1000*1.0 when 'plane' then dur/1000*60 end;
  -- машина: км только на имеющийся бензин (1 ед. = 1 сек газа) + «толкать машину» тапами (как пешком)
  if tr='car' then f := zhol._fuel(r); maxkm := least(maxkm, f*1.5*m*1.02 + 0.02) + 1.1*taps*0.10*m; end if;
  kmv := least(greatest(coalesce(km,0),0), maxkm);
  if coalesce(km,0) > maxkm*1.5 + 0.5 then insert into zhol.log(player,kind,data) values(p,'clamped',jsonb_build_object('km',km,'max',maxkm,'tr',tr)); end if;
  d := zhol._daily(p);
  kmv := least(kmv, greatest(0, coalesce((cfg->>'daily_km_cap')::numeric,2500) - d.km));
  done := (t->>'done')::numeric; total := (t->>'total')::numeric;
  kmv := least(kmv, total-done); done := done + kmv;
  if tr='car' then update zhol.players set fuel = greatest(0, f - greatest(0, kmv - taps*0.10*m)/(1.5*m)), fuel_at = now() where id=p; end if;
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
  origin := coalesce(t->>'origin', path[1]);
  if done >= total - 0.0001 then
    arrived := true;
    node := path[array_length(path,1)];
    update zhol.players set location=node, trip=null, longest_trip=greatest(longest_trip,total), updated_at=now() where id=p;
    insert into zhol.log(player,kind,data) values(p,'arrive',jsonb_build_object('to',node,'from',origin,'via',case when origin<>path[1] then path[1] end,'transport',tr,'km',total));
    perform zhol._ach(p,'first_trip');
    if node='KOR' then perform zhol._ach(p,'first_kor'); end if;
    if tr='horse' and node='KOR' then perform zhol._ach(p,'horse_kor'); end if;
    if node='KOR' then insert into zhol.chat(kind,author_id,text,hidden) values('system',p,r.name||' доехал(а) до Ата и Әже в Кордай 🏡',r.hidden); end if;
    if (origin='ALA' and node='AST') or (origin='AST' and node='ALA') then perform zhol._ach(p,'ala_ast'); end if;
    events := events || jsonb_build_object('type','arrive','node',node);
    if t ? 'challenge' then
      select * into ch from zhol.challenges c where c.id=(t->>'challenge')::bigint for update;
      if ch.id is not null then
        other := case when ch.challenger=p then ch.opponent else ch.challenger end;
        if ch.challenger=p then update zhol.challenges c set challenger_arrived_at=now() where c.id=ch.id; else update zhol.challenges c set opponent_arrived_at=now() where c.id=ch.id; end if;
        if ch.status='active' and ch.winner is null then
          update zhol.challenges c set status='finished', winner=p, loser=other, finished_at=now() where c.id=ch.id;
          got := zhol._race_bonus(p,'win');
          events := events || jsonb_build_object('type','race_win','vs',other,'tokens',got);
        elsif ch.winner<>p then
          got := zhol._race_bonus(p,'lose');
          events := events || jsonb_build_object('type','race_lose','winner',ch.winner,'tokens',got);
        elsif ch.status='cancelled' then
          events := events || jsonb_build_object('type','race_forfeit_win','vs',other);
        end if;
      end if;
    end if;
  else
    update zhol.players set trip = jsonb_set(jsonb_set(jsonb_set(t,'{done}',to_jsonb(round(done,3))),'{last}',to_jsonb(now())),'{collected}',collected), updated_at=now() where id=p;
  end if;
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'km',round(kmv,3),'arrived',arrived,'events',events,'me',zhol._pstate(p));
end $$;

-- ЧАТ: кто пишет — ребёнок (код), родители (код семьи) или админ (PIN)
create or replace function zhol._chat_who(who text, uid text, code text) returns jsonb language plpgsql as $$
declare st text; h boolean; fa zhol.families;
begin
  if who='kid' then st := zhol._auth(uid, code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    select hidden into h from zhol.players where id=uid; return jsonb_build_object('kind','kid','id',uid,'hidden',h,'mod',false);
  elsif who='family' then st := zhol._fauth(uid, code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    select * into fa from zhol.families where id=uid; return jsonb_build_object('kind','family','id',uid,'hidden',fa.hidden,'mod',fa.all_kids);
  elsif who='admin' then st := zhol._pin(code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    return jsonb_build_object('kind','admin','id','admin','hidden',true,'mod',true);
  end if;
  return jsonb_build_object('error','bad_who');
end $$;
revoke all on function zhol._chat_who(text,text,text) from public, anon, authenticated;

create or replace function zhol._chat_list(w jsonb, after bigint) returns jsonb language sql stable as $$
  select jsonb_build_object('ok',true,'mod',(w->>'mod')::boolean,'me',jsonb_build_object('kind',w->>'kind','id',w->>'id'),
    'last',(select coalesce(max(id),0) from zhol.chat),
    'messages',coalesce((select jsonb_agg(m order by (m->>'id')::bigint) from (
      select jsonb_build_object('id',c.id,'kind',c.kind,'author',c.author_id,'text',case when c.deleted then '' else c.text end,'deleted',c.deleted,'at',c.created_at,
        'mine', c.kind=(w->>'kind') and c.author_id=(w->>'id'),
        'name', case c.kind when 'kid' then p.name when 'family' then case when f.all_kids then 'Асет' else 'Родители · '||f.name end when 'admin' then 'Асет (админ)' else 'Жол' end,
        'avatar', case c.kind when 'kid' then p.avatar when 'family' then case when f.all_kids then '🧔' else '👪' end when 'admin' then '🛡️' else '📣' end,
        'color', case c.kind when 'kid' then p.color else null end) m
      from zhol.chat c left join zhol.players p on c.kind in ('kid') and p.id=c.author_id left join zhol.families f on c.kind='family' and f.id=c.author_id
      where c.id > coalesce(after,0) and (not c.hidden or (w->>'hidden')::boolean)
        and c.id > (select coalesce(max(id),0)-80 from zhol.chat)
      order by c.id) x),'[]'::jsonb)) $$;
revoke all on function zhol._chat_list(jsonb,bigint) from public, anon, authenticated;

create or replace function public.zhol_chat(who text, uid text, code text, after bigint default 0) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code);
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  return zhol._chat_list(w, after);
end $$;

create or replace function public.zhol_chat_send(who text, uid text, code text, msg text, after bigint default 0) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code); t text := btrim(coalesce(msg,'')); lastat timestamptz; n int;
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if length(t)=0 then return jsonb_build_object('ok',false,'error','empty'); end if;
  if length(t)>300 then return jsonb_build_object('ok',false,'error','too_long'); end if;
  select max(created_at), count(*) filter (where created_at > date_trunc('day', now() at time zone 'Asia/Almaty') at time zone 'Asia/Almaty') into lastat, n
    from zhol.chat where kind=w->>'kind' and author_id=w->>'id' and created_at > now() - interval '1 day';
  if lastat is not null and now()-lastat < interval '3 seconds' then return jsonb_build_object('ok',false,'error','chat_slow'); end if;
  if n >= 100 then return jsonb_build_object('ok',false,'error','chat_limit'); end if;
  insert into zhol.chat(kind,author_id,text,hidden) values(w->>'kind', w->>'id', t, coalesce((w->>'hidden')::boolean,false) and w->>'kind'<>'admin');
  return zhol._chat_list(w, after);
end $$;

create or replace function public.zhol_chat_delete(who text, uid text, code text, id bigint, after bigint default 0) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare w jsonb := zhol._chat_who(who, uid, code);
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if not (w->>'mod')::boolean then return jsonb_build_object('ok',false,'error','not_allowed'); end if;
  update zhol.chat set deleted=true where zhol.chat.id=zhol_chat_delete.id;
  return zhol._chat_list(w, after);
end $$;
revoke all on function public.zhol_chat(text,text,text,bigint), public.zhol_chat_send(text,text,text,text,bigint), public.zhol_chat_delete(text,text,text,bigint,bigint) from public;
grant execute on function public.zhol_chat(text,text,text,bigint), public.zhol_chat_send(text,text,text,text,bigint), public.zhol_chat_delete(text,text,text,bigint,bigint) to anon, authenticated;

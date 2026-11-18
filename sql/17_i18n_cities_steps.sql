-- 13: языки, справки о городах («Краевед»), шаги -> бонусные км сверх дневного лимита
alter table zhol.players add column if not exists bonus_km numeric not null default 0;
alter table zhol.players add column if not exists cities_read text[] not null default '{}';
alter table zhol.players add column if not exists ui_lang text;
update zhol.settings set value = value || '{"steps_km_per_1000":10}'::jsonb where key='config' and not value ? 'steps_km_per_1000';

CREATE OR REPLACE FUNCTION public.zhol_progress(p text, code text, km numeric, taps integer, dur_ms integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zhol', 'public'
AS $function$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; tr text; dur numeric; m numeric; maxkm numeric; kmv numeric;
  cfg jsonb := zhol._cfg(); d zhol.daily; done numeric; total numeric; path text[]; legs numeric[]; collected jsonb;
  factor numeric; nt int; cum numeric := 0; i int; node text; sv text; g text; events jsonb := '[]'; got int; arrived boolean := false; ch zhol.challenges; other text; origin text; f numeric; capleft numeric; rem numeric; bonus numeric := 0;
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
  -- дневной лимит; сверх лимита — только бонусные км от шагов (подтверждённых родителями)
  capleft := greatest(0, coalesce((cfg->>'daily_km_cap')::numeric,2500) - d.km);
  if kmv > capleft then
    rem := greatest(0, (t->>'total')::numeric - (t->>'done')::numeric - capleft);
    bonus := greatest(0, least(kmv - capleft, coalesce(r.bonus_km,0), rem));
    kmv := capleft + bonus;
    if bonus > 0 then update zhol.players set bonus_km = greatest(0, bonus_km - bonus) where id=p; end if;
  end if;
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
  return jsonb_build_object('ok',true,'km',round(kmv,3),'bonus_used',round(bonus,3),'arrived',arrived,'events',events,'me',zhol._pstate(p));
end $function$
;

CREATE OR REPLACE FUNCTION public.zhol_request(p text, code text, kind text, payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zhol', 'public'
AS $function$
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
    insert into zhol.requests(player,kind,item,cost) values(p,'steps',jsonb_build_object('steps',steps,'km',round(steps/1000.0*coalesce((zhol._cfg()->>'steps_km_per_1000')::numeric,10),1),'comment',left(coalesce(payload->>'comment',''),200)),0);
  else return jsonb_build_object('ok',false,'error','bad_kind'); end if;
  return public.zhol_login(p, code);
end $function$
;

CREATE OR REPLACE FUNCTION zhol._decide(rid bigint, status text, note text, by text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_variable
declare rq zhol.requests; km numeric;
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
      -- шаги -> бонусный запас км (тратится только после дневного лимита); курс — на момент подтверждения
      km := round(least(greatest(coalesce((rq.item->>'steps')::int,0),0),30000)/1000.0*coalesce((zhol._cfg()->>'steps_km_per_1000')::numeric,10),1);
      update zhol.requests set item = item || jsonb_build_object('km',km) where id=rq.id;
      update zhol.players set bonus_km = coalesce(bonus_km,0) + km, updated_at=now() where id=rq.player;
    end if;
  elsif status='rejected' then
    update zhol.requests set status='rejected', decided_at=now(), note=nullif(note,''), decided_by=by where id=rq.id;
    if rq.kind='reward' then update zhol.players set tokens=tokens+rq.cost where id=rq.player; end if;
  else return 'bad_status';
  end if;
  insert into zhol.log(player,kind,data) values(rq.player,'decide',jsonb_build_object('id',rq.id,'status',status,'by',by));
  return 'ok';
end $function$
;

CREATE OR REPLACE FUNCTION zhol._pstate(p text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),'fuel',round(zhol._fuel(pl),2),'stars',stars,'unlocked',unlocked,'bonus_km',round(coalesce(bonus_km,0),1),'ui_lang',ui_lang,'cities_read',cities_read,
    'deeds_today',coalesce((select jsonb_object_agg(c,s) from (select item->>'cat' c, sum((item->>'points')::int) s from zhol.requests where player=p and kind='deed' and status<>'rejected' and (created_at at time zone 'Asia/Almaty')::date=zhol._day() group by 1) x),'{}'::jsonb),
    'deeds_n_today',(select count(*) from zhol.requests where player=p and kind='deed' and (created_at at time zone 'Asia/Almaty')::date=zhol._day()),
    'en',jsonb_build_object('ok',en_ok,'n',en_n,'lvl',zhol._lvl(age),'lang',en_lang,'learned',(select count(*) from zhol.en_words where player=p and last_ok and lang='en'),'kk_learned',(select count(*) from zhol.en_words where player=p and last_ok and lang='kk')),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players pl where id=p $function$
;

CREATE OR REPLACE FUNCTION zhol._test_reset(p text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  if not exists(select 1 from zhol.players where id=p and hidden) then return; end if;
  delete from zhol.requests where player=p;
  delete from zhol.log where player=p;
  delete from zhol.daily where player=p;
  delete from zhol.chat where author_id=p and hidden;
  delete from zhol.challenges where challenger=p or opponent=p;
  delete from zhol.en_quiz where player=p;
  delete from zhol.en_words where player=p;
  update zhol.players set location=home, trip=null, visited=array[home], km_total=0, ticket_km=0, tokens=0, tok_frac=0, tickets=0,
    gifts='{}', delivered='{}', gifts_total=0, achievements='{}', transports='{}', quiz_ok=0, longest_trip=0, en_ok=0, en_n=0,
    fuel=100, fuel_at=now(), fuel_bonus_at=null, stars=0, unlocked='{}', bonus_km=0, cities_read='{}', fails=0, locked_until=null, updated_at=now() where id=p;
end $function$
;

CREATE OR REPLACE FUNCTION zhol._check_ach(p text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
  if r.en_ok>=50 then perform zhol._ach(p,'en50'); end if;
  if r.en_ok>=100 then perform zhol._ach(p,'en100'); end if;
  if r.en_ok>=300 then perform zhol._ach(p,'en300'); end if;
  if coalesce(array_length(r.cities_read,1),0)>=5 then perform zhol._ach(p,'kray5'); end if;
  if coalesce(array_length(r.cities_read,1),0)>=15 then perform zhol._ach(p,'kray15'); end if;
  if coalesce(array_length(r.cities_read,1),0)>=32 then perform zhol._ach(p,'kray32'); end if;
end $function$
;

create or replace function public.zhol_city_read(p text, code text, city text)
returns jsonb language plpgsql security definer set search_path to 'zhol','public' as $function$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); got int := 0; isnew boolean := false;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  if not exists(select 1 from zhol.nodes n where n.id=city) then return jsonb_build_object('ok',false,'error','no_city'); end if;
  perform 1 from zhol.players where id=p for update;
  if not exists(select 1 from zhol.players where id=p and city = any(cities_read)) then
    update zhol.players set cities_read = cities_read || city where id=p;
    isnew := true;
    got := zhol._award(p, 2, 'city_read', true);   -- +2 🪙 один раз за город, в рамках дневного лимита жетонов
    perform zhol._check_ach(p);
  end if;
  return jsonb_build_object('ok',true,'new',isnew,'tokens',got,'me',zhol._pstate(p));
end $function$;
grant execute on function public.zhol_city_read(text,text,text) to anon;

create or replace function public.zhol_ui_lang(p text, code text, lang text)
returns jsonb language plpgsql security definer set search_path to 'zhol','public' as $function$
#variable_conflict use_variable
declare st text := zhol._auth(p, code);
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  if lang not in ('ru','kk','en') then return jsonb_build_object('ok',false,'error','bad_lang'); end if;
  update zhol.players set ui_lang=lang where id=p;
  return jsonb_build_object('ok',true);
end $function$;
grant execute on function public.zhol_ui_lang(text,text,text) to anon;

alter table zhol.players add column if not exists fuel numeric not null default 100,
  add column if not exists fuel_at timestamptz not null default now(),
  add column if not exists fuel_bonus_at timestamptz;
-- бензин: +1 ед. каждые 30 сек, максимум 100; 1 ед. = 1 сек газа = 1.5 км × возрастной коэффициент
create or replace function zhol._fuel(r zhol.players) returns numeric language sql stable as $$
  select least(100, greatest(0, r.fuel) + extract(epoch from now() - r.fuel_at)/30) $$;
revoke all on function zhol._fuel(zhol.players) from public, anon, authenticated;
CREATE OR REPLACE FUNCTION zhol._pstate(p text)
 RETURNS jsonb LANGUAGE sql STABLE AS $function$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),'fuel',round(zhol._fuel(pl),2),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players pl where id=p $function$;
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

-- заправка в пути (события «Заправка» +40 и «Чай» +30): только в поездке на машине, не чаще раза в 35 сек, до 15 раз в день
create or replace function public.zhol_refuel(p text, code text, kind text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; d zhol.daily; c int; n numeric;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  n := case kind when 'station' then 40 when 'tea' then 30 else null end;
  if n is null then return jsonb_build_object('ok',false,'error','bad_kind'); end if;
  select * into r from zhol.players where id=p for update;
  if r.trip is null or r.trip->>'transport'<>'car' then return jsonb_build_object('ok',false,'error','no_trip','me',zhol._pstate(p)); end if;
  if r.fuel_bonus_at is not null and now() - r.fuel_bonus_at < interval '35 seconds' then return jsonb_build_object('ok',true,'added',0,'me',zhol._pstate(p)); end if;
  d := zhol._daily(p); c := coalesce((d.counters->>'refuel')::int,0);
  if c >= 15 then return jsonb_build_object('ok',true,'added',0,'limit',true,'me',zhol._pstate(p)); end if;
  update zhol.daily dd set counters = jsonb_set(dd.counters, '{refuel}', to_jsonb(c+1)) where dd.player=p and dd.day=d.day;
  update zhol.players set fuel = least(100, zhol._fuel(r) + n), fuel_at = now(), fuel_bonus_at = now() where id=p;
  return jsonb_build_object('ok',true,'added',n,'me',zhol._pstate(p));
end $$;
revoke all on function public.zhol_refuel(text,text,text) from public;
grant execute on function public.zhol_refuel(text,text,text) to anon, authenticated;

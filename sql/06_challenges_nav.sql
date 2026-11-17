alter table zhol.players add column if not exists hidden boolean not null default false;
create table if not exists zhol.challenges(
  id bigserial primary key, challenger text not null references zhol.players on delete cascade, opponent text not null references zhol.players on delete cascade,
  path text[] not null, legs numeric[] not null, total numeric not null, transport text not null,
  status text not null default 'pending', winner text, loser text, cancelled_by text,
  created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '24 hours',
  accepted_at timestamptz, finished_at timestamptz, challenger_arrived_at timestamptz, opponent_arrived_at timestamptz);
alter table zhol.challenges enable row level security;

create or replace function zhol._race_bonus(p text, kind text) returns int language plpgsql as $$
declare d zhol.daily; c int; got int := 0;
begin
  if kind='win' then perform zhol._ach(p,'race_win'); end if;
  d := zhol._daily(p); c := coalesce((d.counters->>'race')::int,0);
  if c >= 3 then return 0; end if;
  update zhol.daily set counters = jsonb_set(counters,'{race}',to_jsonb(c+1)) where player=p and day=d.day;
  got := zhol._award(p, case when kind='win' then 15 else 3 end, 'race_'||kind, false);
  return got;
end $$;

-- p покидает активную гонку (отмена/смена поездки) => поражение
create or replace function zhol._race_forfeit(p text) returns void language plpgsql as $$
declare t jsonb; ch zhol.challenges; other text;
begin
  select trip into t from zhol.players where id=p;
  if t is null or not (t ? 'challenge') then return; end if;
  select * into ch from zhol.challenges where id=(t->>'challenge')::bigint for update;
  if ch.id is null or ch.status<>'active' or ch.winner is not null then return; end if;
  other := case when ch.challenger=p then ch.opponent else ch.challenger end;
  update zhol.challenges set status='cancelled', cancelled_by=p, winner=other, loser=p, finished_at=now() where id=ch.id;
  perform zhol._race_bonus(other,'win');
  insert into zhol.log(player,kind,data) values(p,'race_forfeit',jsonb_build_object('challenge',ch.id,'winner',other));
end $$;

create or replace function zhol._race_cancel_pending(p text) returns void language sql as $$
  update zhol.challenges set status='cancelled', cancelled_by=p, finished_at=now() where status='pending' and (challenger=p or opponent=p) $$;

create or replace function zhol._race_expire() returns void language sql as $$
  update zhol.challenges set status='expired', finished_at=now() where status='pending' and expires_at<now() $$;

create or replace function zhol._path_legs(path text[], mode text) returns numeric[] language plpgsql stable as $$
declare legs numeric[] := '{}'; k numeric; i int; n int := coalesce(array_length(path,1),0);
begin
  if n<2 or n>12 then return null; end if;
  if (select count(distinct x) from unnest(path) x) <> n then return null; end if;
  for i in 1..n-1 loop
    k := zhol._edge(path[i], path[i+1], mode);
    if k is null then return null; end if;
    legs := legs || k;
  end loop;
  return legs;
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
  select sum(x) into total from unnest(legs) x;
  insert into zhol.challenges(challenger,opponent,path,legs,total,transport) values(p,opponent,path,legs,total,transport);
  insert into zhol.log(player,kind,data) values(p,'race_create',jsonb_build_object('opponent',opponent,'path',path,'transport',transport));
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.zhol_challenge_respond(p text, code text, id bigint, accept boolean) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); ch zhol.challenges; a zhol.players; b zhol.players; trip jsonb;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  perform zhol._race_expire();
  select * into ch from zhol.challenges c where c.id=zhol_challenge_respond.id for update;
  if ch.id is null or ch.status<>'pending' then return jsonb_build_object('ok',false,'error','no_challenge'); end if;
  if p=ch.challenger and not accept then
    update zhol.challenges set status='cancelled', cancelled_by=p, finished_at=now() where challenges.id=ch.id;
    return jsonb_build_object('ok',true);
  end if;
  if p<>ch.opponent then return jsonb_build_object('ok',false,'error','no_challenge'); end if;
  if not accept then
    update zhol.challenges set status='declined', finished_at=now() where challenges.id=ch.id;
    return jsonb_build_object('ok',true);
  end if;
  select * into a from zhol.players where players.id=ch.challenger for update;
  select * into b from zhol.players where players.id=ch.opponent for update;
  if a.trip is not null or b.trip is not null or a.location<>ch.path[1] or b.location<>ch.path[1] then
    update zhol.challenges set status='expired', finished_at=now() where challenges.id=ch.id;
    return jsonb_build_object('ok',false,'error','not_same_place');
  end if;
  trip := jsonb_build_object('path',to_jsonb(ch.path),'legs',to_jsonb(ch.legs),'total',ch.total,'done',0,'transport',ch.transport,
      'started',now(),'last',now(),'collected','[]'::jsonb,'challenge',ch.id);
  update zhol.players set trip=trip, transports = case when ch.transport = any(transports) then transports else transports||ch.transport end, updated_at=now()
    where players.id in (ch.challenger, ch.opponent);
  update zhol.challenges set status='active', accepted_at=now() where challenges.id=ch.id;
  insert into zhol.log(player,kind,data) values
    (ch.challenger,'start',jsonb_build_object('path',ch.path,'transport',ch.transport,'total',ch.total,'challenge',ch.id,'vs',ch.opponent)),
    (ch.opponent,'start',jsonb_build_object('path',ch.path,'transport',ch.transport,'total',ch.total,'challenge',ch.id,'vs',ch.challenger));
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_progress(p text, code text, km numeric, taps int, dur_ms int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; tr text; dur numeric; m numeric; maxkm numeric; kmv numeric;
  cfg jsonb := zhol._cfg(); d zhol.daily; done numeric; total numeric; path text[]; legs numeric[]; collected jsonb;
  factor numeric; nt int; cum numeric := 0; i int; node text; sv text; g text; events jsonb := '[]'; got int; arrived boolean := false; ch zhol.challenges; other text;
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
  perform zhol._race_forfeit(p); perform zhol._race_cancel_pending(p);
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
  perform zhol._race_forfeit(p);
  update zhol.players set trip=null where id=p;
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
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
end $$;

drop function if exists public.zhol_public_state();
create or replace function public.zhol_public_state(test boolean default false) returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select jsonb_build_object(
    'players',(select jsonb_agg(zhol._pstate(id) order by sort) from zhol.players where not hidden or test),
    'nodes',(select jsonb_agg(to_jsonb(n)) from zhol.nodes n),
    'edges',(select jsonb_agg(to_jsonb(e)) from zhol.edges e),
    'config',(select value - 'secret' from zhol.settings where key='config'),
    'catalog',(select value from zhol.settings where key='catalog'),
    'quests',(select coalesce(jsonb_agg(to_jsonb(q) order by id desc),'[]') from zhol.quests q where active),
    'family',jsonb_build_object(
      'total_km',(select round(sum(km_total),1) from zhol.players where not hidden),
      'week_km',(select coalesce(round(sum(km),1),0) from zhol.daily where player in (select id from zhol.players where not hidden) and day>=date_trunc('week',zhol._day())::date),
      'kordai_today',(select coalesce(jsonb_agg(distinct player),'[]') from zhol.log where player in (select id from zhol.players where not hidden) and kind='arrive' and data->>'to'='KOR' and (at at time zone 'Asia/Almaty')::date=zhol._day()),
      'all_visited',(select coalesce(jsonb_agg(distinct v),'[]') from zhol.players, unnest(visited) v where not hidden),
      'family_ach',(select value from zhol.settings where key='family_ach')),
    'challenges',(select coalesce(jsonb_agg(to_jsonb(c) order by c.id desc),'[]') from (select id,challenger,opponent,path,total,transport,status,winner,loser,cancelled_by,created_at,expires_at,accepted_at,finished_at,challenger_arrived_at,opponent_arrived_at
       from zhol.challenges where ((status='pending' and expires_at>now()) or status='active' or (status in ('finished','cancelled') and accepted_at is not null and finished_at>now()-interval '3 days'))
       and (test or (challenger in (select id from zhol.players where not hidden) and opponent in (select id from zhol.players where not hidden))) order by id desc limit 30) c),
    'today',zhol._day(), 'now', now()) $$;


create or replace function public.zhol_families() returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'all',f.all_kids,
    'kids',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'avatar',p.avatar) order by p.sort),'[]') from zhol.players p where (p.family=f.id or f.all_kids) and not p.hidden)) order by f.sort),'[]')
  from zhol.families f $$;

create or replace function public.zhol_family_login(f text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  return jsonb_build_object('ok',true,
    'family',jsonb_build_object('id',fam.id,'name',fam.name,'all',fam.all_kids),
    'families',(select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort) from zhol.families where not all_kids),
    'kids',(select coalesce(jsonb_agg(zhol._pstate(p.id) || jsonb_build_object('family',p.family) order by p.sort),'[]') from zhol.players p where (p.family=f or fam.all_kids) and not p.hidden),
    'activity',(select coalesce(jsonb_agg(jsonb_build_object('player',l.player,'kind',l.kind,'data',l.data,'at',l.at) order by l.id desc),'[]')
       from (select * from zhol.log where kind in ('start','arrive','ach') and player in (select id from zhol.players where (family=f or fam.all_kids) and not hidden) order by id desc limit 60) l),
    'pub', public.zhol_public_state());
end $$;

revoke all on all functions in schema zhol from public, anon, authenticated;
revoke all on function public.zhol_public_state(boolean), public.zhol_challenge_create(text,text,text,text[],text), public.zhol_challenge_respond(text,text,bigint,boolean) from public;
grant execute on function public.zhol_public_state(boolean), public.zhol_challenge_create(text,text,text,text[],text), public.zhol_challenge_respond(text,text,bigint,boolean) to anon, authenticated;

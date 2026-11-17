alter table zhol.edges add column if not exists rail boolean not null default false;
-- ж/д: Астана–Караганда, Караганда–Балхаш (поезд 605/606 Караганды–Балхаш), Балхаш–Шу (поезд 073Т Алматы–Балхаш через Шу, Мойынты),
-- Шу–Мерке–Тараз (Турксиб), Алматы–Каскелен–Узынагаш (пригородные Алматы-2 – Казыбек-Бек), Алматы–Конаев (пригородный Алматы-1 – Капшагай)
update zhol.edges set rail = ((a,b) in (('KAR','AST'),('BAL','KAR'),('SHU','BAL'),('SHU','MER'),('MER','TAR'),('ALA','KAS'),('KAS','UZY'),('ALA','KON'))
  or (b,a) in (('KAR','AST'),('BAL','KAR'),('SHU','BAL'),('SHU','MER'),('MER','TAR'),('ALA','KAS'),('KAS','UZY'),('ALA','KON'))) where mode='road';
-- самолёт: только проверенные прямые рейсы (Астана–Караганда исключён по решению семьи; Караганда–Тараз прямых нет)
delete from zhol.edges where mode='air' and ((a,b) in (('AST','KAR'),('KAR','TAR')) or (b,a) in (('AST','KAR'),('KAR','TAR')));
create or replace function zhol._path_rail(path text[]) returns boolean language sql stable as $$
  select bool_and(exists(select 1 from zhol.edges e where e.mode='road' and e.rail and ((e.a=path[i] and e.b=path[i+1]) or (e.b=path[i] and e.a=path[i+1]))))
  from generate_series(1, array_length(path,1)-1) i $$;
revoke all on function zhol._path_rail(text[]) from public, anon, authenticated;
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
  perform zhol._race_forfeit(p); perform zhol._race_cancel_pending(p);
  if transport='train' and not zhol._path_rail(path) then return jsonb_build_object('ok',false,'error','no_rail'); end if;
  if transport='plane' then update zhol.players set tickets=tickets-1 where id=p; end if;
  update zhol.players set trip=jsonb_build_object('path',to_jsonb(path),'legs',to_jsonb(legs),'total',total,'done',0,'transport',transport,
      'started',now(),'last',now(),'collected','[]'::jsonb),
    transports = case when transport = any(transports) then transports else transports||transport end, updated_at=now() where id=p;
  insert into zhol.log(player,kind,data) values(p,'start',jsonb_build_object('path',path,'transport',transport,'total',total));
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_progress(p text, code text, km numeric, taps int, dur_ms int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; tr text; dur numeric; m numeric; maxkm numeric; kmv numeric;
  cfg jsonb := zhol._cfg(); d zhol.daily; done numeric; total numeric; path text[]; legs numeric[]; collected jsonb;
  factor numeric; nt int; cum numeric := 0; i int; node text; sv text; g text; events jsonb := '[]'; got int; arrived boolean := false; ch zhol.challenges; other text; origin text;
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
    when 'car' then dur/1000*1.5*m when 'bus' then dur/1000*0.8 when 'train' then dur/1000*1.0 when 'plane' then dur/1000*60 end;
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

create or replace function public.zhol_switch_transport(p text, code text, transport text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare st text := zhol._auth(p, code); r zhol.players; t jsonb; path text[]; legs numeric[]; done numeric; cum numeric := 0; at_i int := null; i int; n int;
  node text; dest text; newpath text[]; newlegs numeric[]; total numeric; k numeric; origin text;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  t := r.trip;
  if t is null then return jsonb_build_object('ok',false,'error','no_trip'); end if;
  if t ? 'challenge' then return jsonb_build_object('ok',false,'error','in_race'); end if;
  if transport not in ('walk','bike','horse','car','bus','train','plane') then return jsonb_build_object('ok',false,'error','bad_transport'); end if;
  select array_agg(x) into path from jsonb_array_elements_text(t->'path') x;
  select array_agg(x::numeric) into legs from jsonb_array_elements_text(t->'legs') x;
  done := (t->>'done')::numeric; n := array_length(path,1);
  -- последняя пройденная промежуточная остановка (сервер уже засчитал её в collected)
  for i in 2..n-1 loop
    if coalesce(t->'collected','[]'::jsonb) ? path[i] then at_i := i; end if;
  end loop;
  if at_i is null then return jsonb_build_object('ok',false,'error','no_stop'); end if;
  node := path[at_i]; dest := path[n]; origin := coalesce(t->>'origin', path[1]);
  if transport='plane' then
    if r.tickets<1 then return jsonb_build_object('ok',false,'error','no_ticket'); end if;
    k := zhol._edge(node, dest, 'air');
    if k is null then return jsonb_build_object('ok',false,'error','no_flight'); end if;
    newpath := array[node, dest]; newlegs := array[k];
  else
    newpath := path[at_i:n]; newlegs := zhol._path_legs(newpath, 'road');
    if newlegs is null then return jsonb_build_object('ok',false,'error','bad_path'); end if;
  end if;
  if transport='train' and not zhol._path_rail(newpath) then return jsonb_build_object('ok',false,'error','no_rail'); end if;
  select sum(x) into total from unnest(newlegs) x;
  perform zhol._race_cancel_pending(p);
  if transport='plane' then update zhol.players set tickets=tickets-1 where id=p; end if;
  -- остановка засчитана как посещение (если вдруг не была), без наград за прибытие
  update zhol.players set location=node, visited = case when node = any(visited) then visited else visited||node end,
    trip=jsonb_build_object('path',to_jsonb(newpath),'legs',to_jsonb(newlegs),'total',total,'done',0,'transport',transport,
      'started',now(),'last',now(),'collected','[]'::jsonb,'origin',origin,
      'prev',coalesce(t->'prev','[]'::jsonb) || jsonb_build_object('transport',t->>'transport','from',path[1],'to',node)),
    transports = case when transport = any(transports) then transports else transports||transport end, updated_at=now() where id=p;
  insert into zhol.log(player,kind,data) values(p,'switch',jsonb_build_object('origin',origin,'at',node,'to',dest,'old',t->>'transport','new',transport));
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;

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
       from (select * from zhol.log where kind in ('start','arrive','ach','switch') and player in (select id from zhol.players where (family=f or fam.all_kids) and not hidden) order by id desc limit 60) l),
    'pub', public.zhol_public_state());
end $$;

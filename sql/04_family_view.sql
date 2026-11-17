create table if not exists zhol.families(id text primary key, name text not null, sort int default 0, code_hash text not null, fails int not null default 0, locked_until timestamptz);
alter table zhol.families enable row level security;
alter table zhol.players add column if not exists family text references zhol.families;

create or replace function zhol._fauth(f text, code text) returns text language plpgsql as $$
declare r zhol.families;
begin
  select * into r from zhol.families where id=f for update;
  if not found then return 'no_family'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if code is null or extensions.crypt(code, r.code_hash) <> r.code_hash then
    if r.fails+1 >= 5 then update zhol.families set fails=0, locked_until=now()+interval '5 minutes' where id=f;
    else update zhol.families set fails=r.fails+1 where id=f; end if;
    return 'bad_code';
  end if;
  if r.fails>0 then update zhol.families set fails=0 where id=f; end if;
  return 'ok';
end $$;

create or replace function public.zhol_families() returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,
    'kids',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'avatar',p.avatar) order by p.sort),'[]') from zhol.players p where p.family=f.id)) order by f.sort),'[]')
  from zhol.families f $$;

create or replace function public.zhol_family_login(f text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._fauth(f, code);
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  return jsonb_build_object('ok',true,
    'family',(select jsonb_build_object('id',id,'name',name) from zhol.families where id=f),
    'kids',(select coalesce(jsonb_agg(zhol._pstate(id) order by sort),'[]') from zhol.players where family=f),
    'activity',(select coalesce(jsonb_agg(jsonb_build_object('player',l.player,'kind',l.kind,'data',l.data,'at',l.at) order by l.id desc),'[]')
       from (select * from zhol.log where kind in ('start','arrive','ach') and player in (select id from zhol.players where family=f) order by id desc limit 40) l),
    'pub', public.zhol_public_state());
end $$;

revoke all on function zhol._fauth(text,text) from public, anon, authenticated;
revoke all on function public.zhol_families(), public.zhol_family_login(text,text) from public;
grant execute on function public.zhol_families(), public.zhol_family_login(text,text) to anon, authenticated;


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


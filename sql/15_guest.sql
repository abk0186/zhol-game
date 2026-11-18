-- 15: временный гостевой вход (тётя Арлана и Аружан), действует до 23:59 18.11.2026 по Алматы — сервер отклоняет вход после срока ('expired').
-- Семья «Гость» (ztest_g): только просмотр всех настоящих детей (как «Все дети»), без прав: не подтверждает запросы настоящих детей,
-- не пишет и не удаляет в чате, без сброса. Подтверждать может только дела своего скрытого гостевого ребёнка «Айзере».
-- Ребёнок «Айзере» (ztest_g1) скрыт, как тестовый: его нет у детей, в рейтингах, итогах и общем чате, жарыс с настоящими детьми невозможен.
alter table zhol.players add column if not exists expires_at timestamptz;
alter table zhol.families add column if not exists expires_at timestamptz, add column if not exists readonly boolean not null default false;

insert into zhol.families(id,name,sort,code_hash,all_kids,hidden,readonly,expires_at)
  values ('ztest_g','Гость',10,extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),true,true,true,'2026-11-18 23:59:59+05')
  on conflict (id) do update set all_kids=true, hidden=true, readonly=true, expires_at=excluded.expires_at;
insert into zhol.players(id,name,age,league,home,school,avatar,color,sort,code_hash,location,visited,family,hidden,expires_at)
  values ('ztest_g1','Айзере',9,'young','ALA','Гостевой вход','🐣','#f2a7c3',100,extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),'ALA',array['ALA'],'ztest_g',true,'2026-11-18 23:59:59+05')
  on conflict (id) do update set expires_at=excluded.expires_at;

-- срок действия входа
CREATE OR REPLACE FUNCTION zhol._auth(p text, code text) RETURNS text LANGUAGE plpgsql AS $function$
declare r zhol.players;
begin
  select * into r from zhol.players where id=p for update;
  if not found then return 'no_player'; end if;
  if r.expires_at is not null and r.expires_at < now() then return 'expired'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if code is null or extensions.crypt(code, r.code_hash) <> r.code_hash then
    if r.fails+1 >= 5 then update zhol.players set fails=0, locked_until=now()+interval '5 minutes' where id=p;
    else update zhol.players set fails=r.fails+1 where id=p; end if;
    return 'bad_code';
  end if;
  if r.fails>0 then update zhol.players set fails=0 where id=p; end if;
  return 'ok';
end $function$;
CREATE OR REPLACE FUNCTION zhol._fauth(f text, code text) RETURNS text LANGUAGE plpgsql AS $function$
declare r zhol.families;
begin
  select * into r from zhol.families where id=f for update;
  if not found then return 'no_family'; end if;
  if r.expires_at is not null and r.expires_at < now() then return 'expired'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if code is null or extensions.crypt(code, r.code_hash) <> r.code_hash then
    if r.fails+1 >= 5 then update zhol.families set fails=0, locked_until=now()+interval '5 minutes' where id=f;
    else update zhol.families set fails=r.fails+1 where id=f; end if;
    return 'bad_code';
  end if;
  if r.fails>0 then update zhol.families set fails=0 where id=f; end if;
  return 'ok';
end $function$;

-- скрытых детей видит только их собственная семья (гость видит настоящих детей + Айзере, но не тестового Асета)
CREATE OR REPLACE FUNCTION public.zhol_family_login(f text, code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'zhol', 'public' AS $function$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  return jsonb_build_object('ok',true,
    'family',jsonb_build_object('id',fam.id,'name',fam.name,'all',fam.all_kids,'ro',fam.readonly,'expires',fam.expires_at),
    'families',(select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort) from zhol.families where not all_kids and not hidden),
    'kids',(select coalesce(jsonb_agg(zhol._pstate(p.id) || jsonb_build_object('family',p.family) order by p.sort),'[]') from zhol.players p where (p.family=f or fam.all_kids) and (not p.hidden or p.family=f)),
    'activity',(select coalesce(jsonb_agg(jsonb_build_object('player',l.player,'kind',l.kind,'data',l.data,'at',l.at) order by l.id desc),'[]')
       from (select * from zhol.log where kind in ('start','arrive','ach','switch') and player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or family=f)) order by id desc limit 60) l),
    'requests',(select coalesce(jsonb_agg(to_jsonb(rq) order by (rq.status='pending') desc, (rq.status='approved') desc, rq.id desc),'[]') from (select * from zhol.requests where player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or family=f)) order by (status in ('pending','approved')) desc, id desc limit 40) rq),
    'pending',(select count(*) from zhol.requests where status='pending' and player in (select id from zhol.players where (family=f or fam.all_kids) and (not hidden or family=f) and (not fam.readonly or family=f))),
    'pub', public.zhol_public_state(fam.hidden));
end $function$;

CREATE OR REPLACE FUNCTION public.zhol_family_decide(f text, code text, id bigint, status text, note text DEFAULT ''::text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'zhol', 'public' AS $function$
#variable_conflict use_variable
declare st text := zhol._fauth(f, code); fam zhol.families; pl text; v text;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where zhol.families.id=f;
  select r.player into pl from zhol.requests r where r.id=zhol_family_decide.id;
  if pl is null or not exists(select 1 from zhol.players p where p.id=pl and (p.family=f or fam.all_kids) and (not p.hidden or p.family=f)) then
    return jsonb_build_object('ok',false,'error','not_your_kid'); end if;
  -- гость (только просмотр) решает только за своего скрытого ребёнка
  if fam.readonly and not exists(select 1 from zhol.players p where p.id=pl and p.family=f and p.hidden) then
    return jsonb_build_object('ok',false,'error','read_only'); end if;
  v := zhol._decide(zhol_family_decide.id, status, note, 'family:'||f);
  if v<>'ok' then return jsonb_build_object('ok',false,'error',v); end if;
  return public.zhol_family_login(f, code);
end $function$;

-- чат: гость читает (видит скрытые тестовые сообщения своих), но не пишет и не модерирует
CREATE OR REPLACE FUNCTION zhol._chat_who(who text, uid text, code text) RETURNS jsonb LANGUAGE plpgsql AS $function$
declare st text; h boolean; fa zhol.families;
begin
  if who='kid' then st := zhol._auth(uid, code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    select hidden into h from zhol.players where id=uid; return jsonb_build_object('kind','kid','id',uid,'hidden',h,'mod',false,'ro',false);
  elsif who='family' then st := zhol._fauth(uid, code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    select * into fa from zhol.families where id=uid; return jsonb_build_object('kind','family','id',uid,'hidden',fa.hidden,'mod',fa.all_kids and not fa.readonly,'ro',fa.readonly);
  elsif who='admin' then st := zhol._pin(code); if st<>'ok' then return jsonb_build_object('error',st); end if;
    return jsonb_build_object('kind','admin','id','admin','hidden',true,'mod',true,'ro',false);
  end if;
  return jsonb_build_object('error','bad_who');
end $function$;

create or replace function public.zhol_chat_send(who text, uid text, code text, msg text, after bigint default 0) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code); t text := btrim(coalesce(msg,'')); lastat timestamptz; n int;
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if coalesce((w->>'ro')::boolean,false) then return jsonb_build_object('ok',false,'error','read_only'); end if;
  if length(t)=0 then return jsonb_build_object('ok',false,'error','empty'); end if;
  if length(t)>300 then return jsonb_build_object('ok',false,'error','too_long'); end if;
  select max(created_at), count(*) filter (where created_at > date_trunc('day', now() at time zone 'Asia/Almaty') at time zone 'Asia/Almaty') into lastat, n
    from zhol.chat where kind=w->>'kind' and author_id=w->>'id' and created_at > now() - interval '1 day';
  if lastat is not null and now()-lastat < interval '3 seconds' then return jsonb_build_object('ok',false,'error','chat_slow'); end if;
  if n >= 100 then return jsonb_build_object('ok',false,'error','chat_limit'); end if;
  insert into zhol.chat(kind,author_id,text,hidden) values(w->>'kind', w->>'id', t, coalesce((w->>'hidden')::boolean,false) and w->>'kind'<>'admin');
  return zhol._chat_list(w, after);
end $$;

CREATE OR REPLACE FUNCTION zhol._chat_list(w jsonb, after bigint) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  select jsonb_build_object('ok',true,'mod',(w->>'mod')::boolean,'ro',coalesce((w->>'ro')::boolean,false),'me',jsonb_build_object('kind',w->>'kind','id',w->>'id'),
    'last',(select coalesce(max(id),0) from zhol.chat),
    'messages',coalesce((select jsonb_agg(m order by (m->>'id')::bigint) from (
      select jsonb_build_object('id',c.id,'kind',c.kind,'author',c.author_id,'text',case when c.deleted then '' else c.text end,'deleted',c.deleted,'at',c.created_at,
        'mine', c.kind=(w->>'kind') and c.author_id=(w->>'id'),
        'name', case c.kind when 'kid' then p.name when 'family' then case when f.all_kids and not f.readonly then 'Асет' else 'Родители · '||f.name end when 'admin' then 'Асет (админ)' else 'Жол' end,
        'avatar', case c.kind when 'kid' then p.avatar when 'family' then case when f.all_kids and not f.readonly then '🧔' else '👪' end when 'admin' then '🛡️' else '📣' end,
        'color', case c.kind when 'kid' then p.color else null end) m
      from zhol.chat c left join zhol.players p on c.kind in ('kid') and p.id=c.author_id left join zhol.families f on c.kind='family' and f.id=c.author_id
      where c.id > coalesce(after,0) and (not c.hidden or (w->>'hidden')::boolean)
        and c.id > (select coalesce(max(id),0)-80 from zhol.chat)
      order by c.id) x),'[]'::jsonb)) $function$;

CREATE OR REPLACE FUNCTION public.zhol_test_reset(f text, code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'zhol', 'public' AS $function$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  if not fam.hidden then return jsonb_build_object('ok',false,'error','not_test'); end if;
  if fam.readonly then return jsonb_build_object('ok',false,'error','read_only'); end if;
  perform zhol._test_reset(x.id) from zhol.players x where x.family=f and x.hidden;
  return public.zhol_family_login(f, code);
end $function$;

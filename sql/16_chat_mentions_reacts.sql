-- 16: чат — @упоминания и эмодзи-реакции.
-- Участники для @: настоящие дети, «Родители · <семья>», «Асет» (семья «Все дети»). Тестовые/гостевые входы видят и упоминают только участников своего
-- изолированного круга (скрытые дети/семья с тем же family). Сервер хранит id упомянутых (zhol.chat_mentions) и принимает только допустимых.
-- Реакции: 👍 ❤️ 😂 😮 👏 🔥 🙏 🎉, одна на эмодзи от человека, повторное нажатие убирает; не больше 30 в минуту; гость «только чтение» не реагирует;
-- скрытые (тестовые) участники реагируют только на скрытые сообщения своего круга, их реакции видят только скрытые.
create table if not exists zhol.chat_mentions(chat_id bigint not null references zhol.chat on delete cascade, kind text not null, target text not null, primary key(chat_id,kind,target));
create table if not exists zhol.chat_reacts(chat_id bigint not null references zhol.chat on delete cascade, kind text not null, uid text not null, emoji text not null,
  hidden boolean not null default false, at timestamptz not null default now(), primary key(chat_id,kind,uid,emoji));
create index if not exists chat_reacts_who on zhol.chat_reacts(kind, uid, at desc);
alter table zhol.chat_mentions enable row level security; alter table zhol.chat_reacts enable row level security;

-- круг собеседника: null — настоящие участники; иначе id скрытой семьи (тестовой или гостевой)
create or replace function zhol._chat_scope(w jsonb) returns text language sql stable as $$
  select case when w->>'kind'='kid' then (select family from zhol.players where id=w->>'id' and hidden)
              when w->>'kind'='family' then (select id from zhol.families where id=w->>'id' and hidden) else null end $$;

create or replace function zhol._chat_people(w jsonb) returns table(kind text, id text, name text, avatar text, sort int) language sql stable as $$
  with s as (select zhol._chat_scope(w) sc)
  select 'kid', p.id, p.name, p.avatar, p.sort from zhol.players p, s where (s.sc is null and not p.hidden) or (p.hidden and p.family=s.sc)
  union all
  select 'family', f.id, case when f.all_kids and not f.readonly then 'Асет' else 'Родители · '||f.name end, case when f.all_kids and not f.readonly then '🧔' else '👪' end, 1000+f.sort
    from zhol.families f, s where (s.sc is null and not f.hidden) or (f.hidden and f.id=s.sc) $$;

-- кого считать «мной» для упоминаний (админ = «Асет»)
create or replace function zhol._chat_me_match(w jsonb, k text, t text) returns boolean language sql stable as $$
  select (k=w->>'kind' and t=w->>'id') or (w->>'kind'='admin' and k='family' and exists(select 1 from zhol.families where id=t and all_kids and not readonly and not hidden)) $$;

CREATE OR REPLACE FUNCTION zhol._chat_list(w jsonb, after bigint) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  with win as (select coalesce(max(id),0)-80 lo from zhol.chat),
  vis as (select c.* from zhol.chat c, win where c.id > win.lo and (not c.hidden or (w->>'hidden')::boolean))
  select jsonb_build_object('ok',true,'mod',(w->>'mod')::boolean,'ro',coalesce((w->>'ro')::boolean,false),'me',jsonb_build_object('kind',w->>'kind','id',w->>'id'),
    'last',(select coalesce(max(id),0) from zhol.chat),
    'people',(select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'id',id,'name',name,'avatar',avatar) order by sort),'[]') from zhol._chat_people(w)),
    'messages',coalesce((select jsonb_agg(m order by (m->>'id')::bigint) from (
      select jsonb_build_object('id',c.id,'kind',c.kind,'author',c.author_id,'text',case when c.deleted then '' else c.text end,'deleted',c.deleted,'at',c.created_at,
        'mine', c.kind=(w->>'kind') and c.author_id=(w->>'id'),
        'name', case c.kind when 'kid' then p.name when 'family' then case when f.all_kids and not f.readonly then 'Асет' else 'Родители · '||f.name end when 'admin' then 'Асет (админ)' else 'Жол' end,
        'avatar', case c.kind when 'kid' then p.avatar when 'family' then case when f.all_kids and not f.readonly then '🧔' else '👪' end when 'admin' then '🛡️' else '📣' end,
        'color', case c.kind when 'kid' then p.color else null end,
        'mentions',(select coalesce(jsonb_agg(jsonb_build_object('kind',cm.kind,'id',cm.target)),'[]') from zhol.chat_mentions cm where cm.chat_id=c.id),
        'at_me',(not c.deleted and exists(select 1 from zhol.chat_mentions cm where cm.chat_id=c.id and zhol._chat_me_match(w, cm.kind, cm.target)))) m
      from vis c left join zhol.players p on c.kind in ('kid') and p.id=c.author_id left join zhol.families f on c.kind='family' and f.id=c.author_id
      where c.id > coalesce(after,0)
      order by c.id) x),'[]'::jsonb),
    'rx',coalesce((select jsonb_object_agg(chat_id, arr) from (
      select r.chat_id, jsonb_agg(jsonb_build_object('e',r.emoji,'n',r.n,'who',r.who,'mine',r.mine) order by r.first) arr from (
        select cr.chat_id, cr.emoji, count(*) n, min(cr.at) first,
          jsonb_agg(case cr.kind when 'kid' then (select name from zhol.players where id=cr.uid) when 'admin' then 'Асет (админ)'
            else (select case when all_kids and not readonly then 'Асет' else 'Родители · '||name end from zhol.families where id=cr.uid) end order by cr.at) who,
          bool_or(cr.kind=w->>'kind' and cr.uid=w->>'id') mine
        from zhol.chat_reacts cr join vis on vis.id=cr.chat_id
        where not cr.hidden or (w->>'hidden')::boolean
        group by cr.chat_id, cr.emoji) r group by r.chat_id) y),'{}'::jsonb)) $function$;

drop function if exists public.zhol_chat_send(text,text,text,text,bigint);
create or replace function public.zhol_chat_send(who text, uid text, code text, msg text, after bigint default 0, mentions jsonb default '[]') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code); t text := btrim(coalesce(msg,'')); lastat timestamptz; n int; cid bigint;
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if coalesce((w->>'ro')::boolean,false) then return jsonb_build_object('ok',false,'error','read_only'); end if;
  if length(t)=0 then return jsonb_build_object('ok',false,'error','empty'); end if;
  if length(t)>300 then return jsonb_build_object('ok',false,'error','too_long'); end if;
  select max(created_at), count(*) filter (where created_at > date_trunc('day', now() at time zone 'Asia/Almaty') at time zone 'Asia/Almaty') into lastat, n
    from zhol.chat where kind=w->>'kind' and author_id=w->>'id' and created_at > now() - interval '1 day';
  if lastat is not null and now()-lastat < interval '3 seconds' then return jsonb_build_object('ok',false,'error','chat_slow'); end if;
  if n >= 100 then return jsonb_build_object('ok',false,'error','chat_limit'); end if;
  insert into zhol.chat(kind,author_id,text,hidden) values(w->>'kind', w->>'id', t, coalesce((w->>'hidden')::boolean,false) and w->>'kind'<>'admin') returning id into cid;
  -- упоминания: только допустимые участники своего круга, не себя, до 10, и имя должно быть в тексте
  insert into zhol.chat_mentions(chat_id,kind,target)
    select distinct cid, pp.kind, pp.id from jsonb_array_elements(case when jsonb_typeof(mentions)='array' then mentions else '[]'::jsonb end) with ordinality x(v,i)
      join zhol._chat_people(w) pp on pp.kind=x.v->>'kind' and pp.id=x.v->>'id'
      where x.i<=10 and not (pp.kind=w->>'kind' and pp.id=w->>'id') and position('@'||pp.name in t)>0
    on conflict do nothing;
  return zhol._chat_list(w, after);
end $$;
grant execute on function public.zhol_chat_send(text,text,text,text,bigint,jsonb) to anon, authenticated;

create or replace function public.zhol_chat_react(who text, uid text, code text, id bigint, emoji text, after bigint default 0) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
#variable_conflict use_variable
declare w jsonb := zhol._chat_who(who, uid, code); c zhol.chat; hid boolean; n int;
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if coalesce((w->>'ro')::boolean,false) then return jsonb_build_object('ok',false,'error','read_only'); end if;
  if emoji not in ('👍','❤️','😂','😮','👏','🔥','🙏','🎉') then return jsonb_build_object('ok',false,'error','bad_emoji'); end if;
  select * into c from zhol.chat where zhol.chat.id=zhol_chat_react.id;
  if c.id is null or c.deleted or c.id <= (select coalesce(max(x.id),0)-80 from zhol.chat x) then return jsonb_build_object('ok',false,'error','no_message'); end if;
  hid := coalesce((w->>'hidden')::boolean,false) and w->>'kind'<>'admin';
  if c.hidden and not coalesce((w->>'hidden')::boolean,false) then return jsonb_build_object('ok',false,'error','no_message'); end if;
  if hid and not c.hidden then return jsonb_build_object('ok',false,'error','test_scope'); end if;
  select count(*) into n from zhol.chat_reacts r where r.kind=w->>'kind' and r.uid=w->>'id' and r.at > now() - interval '1 minute';
  if n >= 30 then return jsonb_build_object('ok',false,'error','chat_slow'); end if;
  if exists(select 1 from zhol.chat_reacts r where r.chat_id=c.id and r.kind=w->>'kind' and r.uid=w->>'id' and r.emoji=emoji) then
    delete from zhol.chat_reacts r where r.chat_id=c.id and r.kind=w->>'kind' and r.uid=w->>'id' and r.emoji=emoji;
  else
    insert into zhol.chat_reacts(chat_id,kind,uid,emoji,hidden) values(c.id, w->>'kind', w->>'id', emoji, hid);
  end if;
  return zhol._chat_list(w, after);
end $$;
grant execute on function public.zhol_chat_react(text,text,text,bigint,text,bigint) to anon, authenticated;

-- 18: онлайн-статус (last_seen + heartbeat + presence).
-- last_seen у детей и семей; heartbeat при входе и раз в ~60 с, пока вкладка видна.
-- На сервере обновление чаще чем раз в 30 с игнорируется.
-- zhol_presence отдаёт last_seen только видимым детям и семьям:
--   настоящие дети и семьи не видят скрытых (тест «Тест (Асет)», гость «Айзере»);
--   скрытый ребёнок видит настоящих и своих скрытых из той же семьи;
--   семья: свои дети, либо все настоящие + свои скрытые, если all_kids (в т.ч. гость);
--   админ: как обзор — только нескрытые.

alter table zhol.players add column if not exists last_seen timestamptz;
alter table zhol.families add column if not exists last_seen timestamptz;

create or replace function zhol._vis_kids(w jsonb)
returns table(id text, last_seen timestamptz) language sql stable as $$
  select p.id, p.last_seen from zhol.players p
  where case
    when w->>'kind'='kid' then
      case when coalesce((w->>'hidden')::boolean,false)
        then (not p.hidden or p.family=(select family from zhol.players where zhol.players.id=w->>'id'))
        else not p.hidden end
    when w->>'kind'='family' then
      exists(select 1 from zhol.families f where f.id=w->>'id'
        and (p.family=f.id or f.all_kids) and (not p.hidden or p.family=f.id))
    when w->>'kind'='admin' then not p.hidden
    else false end
$$;

create or replace function zhol._vis_fams(w jsonb)
returns table(id text, last_seen timestamptz) language sql stable as $$
  select f.id, f.last_seen from zhol.families f
  where case
    when w->>'kind'='kid' then
      case when coalesce((w->>'hidden')::boolean,false)
        then (not f.hidden or f.id=(select family from zhol.players where zhol.players.id=w->>'id'))
        else not f.hidden end
    when w->>'kind'='family' then
      case when exists(select 1 from zhol.families x where x.id=w->>'id' and x.hidden and not x.all_kids)
        then f.id = w->>'id'
        when exists(select 1 from zhol.families x where x.id=w->>'id' and x.hidden)
        then not f.hidden or f.id = w->>'id'
        else not f.hidden end
    when w->>'kind'='admin' then not f.hidden
    else false end
$$;

revoke all on function zhol._vis_kids(jsonb), zhol._vis_fams(jsonb) from public, anon, authenticated;

create or replace function public.zhol_heartbeat(who text, uid text, code text)
returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code);
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  if w->>'kind'='kid' then
    update zhol.players set last_seen=now()
      where id=w->>'id' and (last_seen is null or last_seen < now() - interval '30 seconds');
  elsif w->>'kind'='family' then
    update zhol.families set last_seen=now()
      where id=w->>'id' and (last_seen is null or last_seen < now() - interval '30 seconds');
  end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.zhol_presence(who text, uid text, code text)
returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare w jsonb := zhol._chat_who(who, uid, code);
begin
  if w ? 'error' then return jsonb_build_object('ok',false,'error',w->>'error'); end if;
  return jsonb_build_object('ok',true,'now',now(),
    'kids',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'last_seen',last_seen) order by id),'[]') from zhol._vis_kids(w)),
    'families',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'last_seen',last_seen) order by id),'[]') from zhol._vis_fams(w)));
end $$;

revoke all on function public.zhol_heartbeat(text,text,text), public.zhol_presence(text,text,text) from public;
grant execute on function public.zhol_heartbeat(text,text,text), public.zhol_presence(text,text,text) to anon, authenticated;

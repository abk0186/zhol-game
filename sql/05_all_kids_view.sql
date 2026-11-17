alter table zhol.families add column if not exists all_kids boolean not null default false;

create or replace function public.zhol_families() returns jsonb language sql stable security definer set search_path=zhol,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'all',f.all_kids,
    'kids',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'avatar',p.avatar) order by p.sort),'[]') from zhol.players p where p.family=f.id or f.all_kids)) order by f.sort),'[]')
  from zhol.families f $$;

create or replace function public.zhol_family_login(f text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  return jsonb_build_object('ok',true,
    'family',jsonb_build_object('id',fam.id,'name',fam.name,'all',fam.all_kids),
    'families',(select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort) from zhol.families where not all_kids),
    'kids',(select coalesce(jsonb_agg(zhol._pstate(p.id) || jsonb_build_object('family',p.family) order by p.sort),'[]') from zhol.players p where p.family=f or fam.all_kids),
    'activity',(select coalesce(jsonb_agg(jsonb_build_object('player',l.player,'kind',l.kind,'data',l.data,'at',l.at) order by l.id desc),'[]')
       from (select * from zhol.log where kind in ('start','arrive','ach') and player in (select id from zhol.players where family=f or fam.all_kids) order by id desc limit 60) l),
    'pub', public.zhol_public_state());
end $$;
revoke all on function public.zhol_families(), public.zhol_family_login(text,text) from public;
grant execute on function public.zhol_families(), public.zhol_family_login(text,text) to anon, authenticated;

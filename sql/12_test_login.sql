-- 12: постоянный тестовый вход для Асета (скрытый ребёнок + скрытая семья «Тест») и сброс прогресса тестового
-- Скрытые (hidden) игроки не попадают в общие итоги, рейтинги, «Все дети (Асет)», семейные просмотры и общий чат;
-- жарыс возможен только между скрытыми игроками (zhol_challenge_create: b.hidden<>a.hidden → no_player).
-- Коды задаются отдельно (не в репозитории): update ... set code_hash=extensions.crypt('<код>', extensions.gen_salt('bf')).
insert into zhol.families(id,name,sort,code_hash,all_kids,hidden)
  values ('ztest','Тест',9,extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),false,true) on conflict (id) do nothing;
insert into zhol.players(id,name,age,league,home,school,avatar,color,sort,code_hash,location,visited,family,hidden)
  values ('ztest_asset','Тест (Асет)',10,'young','AST','Тестовый вход','🧪','#7a5cff',99,extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),'AST',array['AST'],'ztest',true)
  on conflict (id) do nothing;

create or replace function zhol._test_reset(p text) returns void language plpgsql as $$
begin
  if not exists(select 1 from zhol.players where id=p and hidden) then return; end if;
  delete from zhol.requests where player=p;
  delete from zhol.log where player=p;
  delete from zhol.daily where player=p;
  delete from zhol.chat where author_id=p and hidden;
  delete from zhol.challenges where challenger=p or opponent=p;
  update zhol.players set location=home, trip=null, visited=array[home], km_total=0, ticket_km=0, tokens=0, tok_frac=0, tickets=0,
    gifts='{}', delivered='{}', gifts_total=0, achievements='{}', transports='{}', quiz_ok=0, longest_trip=0,
    fuel=100, fuel_at=now(), fuel_bonus_at=null, stars=0, unlocked='{}', fails=0, locked_until=null, updated_at=now() where id=p;
end $$;
revoke all on function zhol._test_reset(text) from public, anon, authenticated;

-- сброс доступен только скрытой (тестовой) семье и только для её скрытых детей
create or replace function public.zhol_test_reset(f text, code text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._fauth(f, code); fam zhol.families;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into fam from zhol.families where id=f;
  if not fam.hidden then return jsonb_build_object('ok',false,'error','not_test'); end if;
  perform zhol._test_reset(x.id) from zhol.players x where x.family=f and x.hidden;
  return public.zhol_family_login(f, code);
end $$;
revoke all on function public.zhol_test_reset(text,text) from public;
grant execute on function public.zhol_test_reset(text,text) to anon, authenticated;

-- 13: 📘 English в дороге — карточки слов во время поездки + мини-тест «Выбери перевод».
-- Сервер хранит словарь (zhol.words: id → en/ru), сам выдаёт вопрос (zhol_en_quiz: слово + 4 варианта, верный индекс хранится только в БД)
-- и сам проверяет ответ (zhol_en_answer). Награда: +1 🪙 за верный ответ, не больше config.en_daily_tokens (10) в день и в общем дневном лимите жетонов.
-- Защита: вопрос только во время поездки, не чаще раза в 20 сек, ответ — один раз и в течение 3 минут, не больше 120 вопросов в день.
create table if not exists zhol.words(id text primary key, lvl text not null, cat text not null default '', en text not null, ru text not null);
create table if not exists zhol.en_quiz(id bigserial primary key, player text not null references zhol.players on delete cascade, word text not null references zhol.words,
  mode text not null, options jsonb not null, answer int not null, created_at timestamptz not null default now(), answered_at timestamptz, correct boolean);
create index if not exists en_quiz_player on zhol.en_quiz(player, id desc);
create table if not exists zhol.en_words(player text not null references zhol.players on delete cascade, word text not null references zhol.words,
  ok int not null default 0, bad int not null default 0, last_ok boolean, at timestamptz not null default now(), primary key(player, word));
alter table zhol.words enable row level security; alter table zhol.en_quiz enable row level security; alter table zhol.en_words enable row level security;
alter table zhol.players add column if not exists en_ok int not null default 0, add column if not exists en_n int not null default 0;
update zhol.settings set value = value || '{"en_daily_tokens":10}'::jsonb where key='config' and not (value ? 'en_daily_tokens');

create or replace function zhol._lvl(age int) returns text language sql immutable as $$ select case when age<=11 then 'a1' when age<=14 then 'a2' else 'b1' end $$;

create or replace function public.zhol_en_quiz(p text, code text, w text default null, mode text default 'en2ru') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); r zhol.players; wd zhol.words; opts jsonb; ans int; d zhol.daily; qn int; qid bigint;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if r.trip is null then return jsonb_build_object('ok',false,'error','no_trip'); end if;
  if exists(select 1 from zhol.en_quiz where player=p and created_at > now() - interval '20 seconds') then return jsonb_build_object('ok',false,'error','too_soon'); end if;
  d := zhol._daily(p); qn := coalesce((d.counters->>'en_q')::int,0);
  if qn >= 120 then return jsonb_build_object('ok',false,'error','too_many'); end if;
  update zhol.daily set counters = jsonb_set(counters,'{en_q}',to_jsonb(qn+1)) where player=p and day=d.day;
  if mode not in ('en2ru','ru2en') then mode := 'en2ru'; end if;
  select * into wd from zhol.words where id=w and words.lvl=zhol._lvl(r.age);
  if wd.id is null then select * into wd from zhol.words where words.lvl=zhol._lvl(r.age) order by random() limit 1; end if;
  -- 3 неверных варианта того же уровня (сначала из той же темы), без совпадений по переводу
  select jsonb_agg(x.v order by x.o) into opts from (
    select case when mode='en2ru' then ru else en end v, random() o from (
      (select ru, en from zhol.words where words.id=wd.id)
      union all
      (select ru, en from zhol.words where words.lvl=wd.lvl and words.id<>wd.id and ru<>wd.ru and en<>wd.en order by (cat=wd.cat) desc, random() limit 3)) y) x;
  select i-1 into ans from jsonb_array_elements_text(opts) with ordinality t(v,i) where v = case when mode='en2ru' then wd.ru else wd.en end limit 1;
  delete from zhol.en_quiz where player=p and answered_at is null;
  insert into zhol.en_quiz(player,word,mode,options,answer) values(p,wd.id,mode,opts,ans) returning id into qid;
  return jsonb_build_object('ok',true,'id',qid,'word',wd.id,'mode',mode,'prompt',case when mode='en2ru' then wd.en else wd.ru end,'options',opts);
end $$;

create or replace function public.zhol_en_answer(p text, code text, q bigint, choice int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); z zhol.en_quiz; good boolean; d zhol.daily; c int; cap int; got int := 0; lim boolean := false;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into z from zhol.en_quiz where id=q and player=p and answered_at is null and created_at > now() - interval '3 minutes' for update;
  if z.id is null then return jsonb_build_object('ok',false,'error','bad_quiz'); end if;
  good := (choice = z.answer);
  update zhol.en_quiz set answered_at=now(), correct=good where id=z.id;
  insert into zhol.en_words(player,word,ok,bad,last_ok,at) values(p,z.word,case when good then 1 else 0 end,case when good then 0 else 1 end,good,now())
    on conflict (player,word) do update set ok=en_words.ok+excluded.ok, bad=en_words.bad+excluded.bad, last_ok=excluded.last_ok, at=now();
  update zhol.players set en_n=en_n+1, en_ok=en_ok+case when good then 1 else 0 end, updated_at=now() where id=p;
  if good then
    d := zhol._daily(p); c := coalesce((d.counters->>'en')::int,0); cap := coalesce((zhol._cfg()->>'en_daily_tokens')::int,10);
    if c < cap then
      got := zhol._award(p, 1, 'english', true);
      if got > 0 then update zhol.daily set counters = jsonb_set(counters,'{en}',to_jsonb(c+1)) where player=p and day=d.day; else lim := true; end if;
    else lim := true; end if;
  end if;
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'correct',good,'answer',z.answer,'answer_text',z.options->>z.answer,'tokens',got,'limit',lim,'me',zhol._pstate(p));
end $$;
grant execute on function public.zhol_en_quiz(text,text,text,text) to anon, authenticated;
grant execute on function public.zhol_en_answer(text,text,bigint,int) to anon, authenticated;

-- достижения 📘 English: 50 / 100 / 300 верных ответов
create or replace function zhol._check_ach(p text) returns void language plpgsql as $$
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
end $$;

-- состояние игрока + English: верно/всего, выучено (последний ответ по слову верный), уровень, жетоны за сегодня
CREATE OR REPLACE FUNCTION zhol._pstate(p text) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),'fuel',round(zhol._fuel(pl),2),'stars',stars,'unlocked',unlocked,
    'deeds_today',coalesce((select jsonb_object_agg(c,s) from (select item->>'cat' c, sum((item->>'points')::int) s from zhol.requests where player=p and kind='deed' and status<>'rejected' and (created_at at time zone 'Asia/Almaty')::date=zhol._day() group by 1) x),'{}'::jsonb),
    'deeds_n_today',(select count(*) from zhol.requests where player=p and kind='deed' and (created_at at time zone 'Asia/Almaty')::date=zhol._day()),
    'en',jsonb_build_object('ok',en_ok,'n',en_n,'lvl',zhol._lvl(age),'learned',(select count(*) from zhol.en_words where player=p and last_ok)),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players pl where id=p $function$;

-- сброс тестового: теперь и English
create or replace function zhol._test_reset(p text) returns void language plpgsql as $$
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
    fuel=100, fuel_at=now(), fuel_bonus_at=null, stars=0, unlocked='{}', fails=0, locked_until=null, updated_at=now() where id=p;
end $$;
revoke all on function zhol._test_reset(text) from public, anon, authenticated;

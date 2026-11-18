-- 14: 🇰🇿 Қазақша в дороге — тот же механизм карточек и мини-тестов, но для казахских слов (базовый уровень, школьная программа 9–11 лет).
-- Язык карточек у каждого ребёнка: en (English), kk (Қазақша), both (по очереди). Арлану по умолчанию — both (просьба Асета: ему нужен казахский).
-- Награда и лимит общие с English: +1 🪙 за верный ответ, не больше config.en_daily_tokens (10) в день.
alter table zhol.words add column if not exists kk text not null default '';
alter table zhol.players add column if not exists en_lang text not null default 'en';
alter table zhol.players drop constraint if exists players_en_lang_chk;
alter table zhol.players add constraint players_en_lang_chk check (en_lang in ('en','kk','both'));
update zhol.players set en_lang='both' where id='arlan';
alter table zhol.en_quiz add column if not exists lang text not null default 'en';
alter table zhol.en_words add column if not exists lang text not null default 'en';
alter table zhol.en_words drop constraint if exists en_words_pkey;
alter table zhol.en_words add primary key (player, word, lang);

create or replace function public.zhol_en_quiz(p text, code text, w text default null, mode text default 'en2ru') returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); r zhol.players; wd zhol.words; opts jsonb; ans int; d zhol.daily; qn int; qid bigint; lang text;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into r from zhol.players where id=p for update;
  if r.trip is null then return jsonb_build_object('ok',false,'error','no_trip'); end if;
  if exists(select 1 from zhol.en_quiz where player=p and created_at > now() - interval '20 seconds') then return jsonb_build_object('ok',false,'error','too_soon'); end if;
  d := zhol._daily(p); qn := coalesce((d.counters->>'en_q')::int,0);
  if qn >= 120 then return jsonb_build_object('ok',false,'error','too_many'); end if;
  update zhol.daily set counters = jsonb_set(counters,'{en_q}',to_jsonb(qn+1)) where player=p and day=d.day;
  if mode not in ('en2ru','ru2en','kk2ru','ru2kk') then mode := 'en2ru'; end if;
  lang := case when mode in ('kk2ru','ru2kk') then 'kk' else 'en' end;
  -- английский — по возрасту; казахский — базовый уровень (слова a1, где есть казахский перевод)
  if lang='kk' then
    select * into wd from zhol.words where id=w and kk<>'';
    if wd.id is null then select * into wd from zhol.words where kk<>'' order by random() limit 1; end if;
  else
    select * into wd from zhol.words where id=w and words.lvl=zhol._lvl(r.age);
    if wd.id is null then select * into wd from zhol.words where words.lvl=zhol._lvl(r.age) order by random() limit 1; end if;
  end if;
  -- 3 неверных варианта того же уровня (сначала из той же темы), без совпадений по переводу
  select jsonb_agg(x.v order by x.o) into opts from (
    select case when mode in ('en2ru','kk2ru') then ru when mode='ru2kk' then kk else en end v, random() o from (
      (select ru, en, kk from zhol.words where words.id=wd.id)
      union all
      (select ru, en, kk from zhol.words where words.lvl=wd.lvl and words.id<>wd.id and ru<>wd.ru and en<>wd.en and (lang='en' or (kk<>'' and kk<>wd.kk))
         order by (cat=wd.cat) desc, random() limit 3)) y) x;
  select i-1 into ans from jsonb_array_elements_text(opts) with ordinality t(v,i)
    where v = case when mode in ('en2ru','kk2ru') then wd.ru when mode='ru2kk' then wd.kk else wd.en end limit 1;
  delete from zhol.en_quiz where player=p and answered_at is null;
  insert into zhol.en_quiz(player,word,mode,options,answer,lang) values(p,wd.id,mode,opts,ans,lang) returning id into qid;
  return jsonb_build_object('ok',true,'id',qid,'word',wd.id,'mode',mode,'lang',lang,'prompt',case mode when 'en2ru' then wd.en when 'kk2ru' then wd.kk else wd.ru end,'options',opts);
end $$;

create or replace function public.zhol_en_answer(p text, code text, q bigint, choice int) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code); z zhol.en_quiz; good boolean; d zhol.daily; c int; cap int; got int := 0; lim boolean := false;
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  select * into z from zhol.en_quiz where id=q and player=p and answered_at is null and created_at > now() - interval '3 minutes' for update;
  if z.id is null then return jsonb_build_object('ok',false,'error','bad_quiz'); end if;
  good := (choice = z.answer);
  update zhol.en_quiz set answered_at=now(), correct=good where id=z.id;
  insert into zhol.en_words(player,word,lang,ok,bad,last_ok,at) values(p,z.word,z.lang,case when good then 1 else 0 end,case when good then 0 else 1 end,good,now())
    on conflict (player,word,lang) do update set ok=en_words.ok+excluded.ok, bad=en_words.bad+excluded.bad, last_ok=excluded.last_ok, at=now();
  update zhol.players set en_n=en_n+1, en_ok=en_ok+case when good then 1 else 0 end, updated_at=now() where id=p;
  if good then
    d := zhol._daily(p); c := coalesce((d.counters->>'en')::int,0); cap := coalesce((zhol._cfg()->>'en_daily_tokens')::int,10);
    if c < cap then
      got := zhol._award(p, 1, 'english', true);
      if got > 0 then update zhol.daily set counters = jsonb_set(counters,'{en}',to_jsonb(c+1)) where player=p and day=d.day; else lim := true; end if;
    else lim := true; end if;
  end if;
  perform zhol._check_ach(p);
  return jsonb_build_object('ok',true,'correct',good,'answer',z.answer,'answer_text',z.options->>z.answer,'lang',z.lang,'tokens',got,'limit',lim,'me',zhol._pstate(p));
end $$;

create or replace function public.zhol_en_lang(p text, code text, lang text) returns jsonb language plpgsql security definer set search_path=zhol,public as $$
declare st text := zhol._auth(p, code);
begin
  if st<>'ok' then return jsonb_build_object('ok',false,'error',st); end if;
  if lang not in ('en','kk','both') then return jsonb_build_object('ok',false,'error','bad_lang'); end if;
  update zhol.players set en_lang=lang, updated_at=now() where id=p;
  return jsonb_build_object('ok',true,'me',zhol._pstate(p));
end $$;
grant execute on function public.zhol_en_lang(text,text,text) to anon, authenticated;

CREATE OR REPLACE FUNCTION zhol._pstate(p text) RETURNS jsonb LANGUAGE sql STABLE AS $function$
  select jsonb_build_object('id',id,'name',name,'age',age,'league',league,'home',home,'school',school,'avatar',avatar,'color',color,
    'location',location,'trip',trip,'km_total',round(km_total,1),'tokens',tokens,'tickets',tickets,'ticket_km',round(ticket_km,1),
    'visited',visited,'gifts',gifts,'delivered',delivered,'gifts_total',gifts_total,'achievements',achievements,'transports',transports,
    'quiz_ok',quiz_ok,'longest_trip',round(longest_trip,1),'fuel',round(zhol._fuel(pl),2),'stars',stars,'unlocked',unlocked,
    'deeds_today',coalesce((select jsonb_object_agg(c,s) from (select item->>'cat' c, sum((item->>'points')::int) s from zhol.requests where player=p and kind='deed' and status<>'rejected' and (created_at at time zone 'Asia/Almaty')::date=zhol._day() group by 1) x),'{}'::jsonb),
    'deeds_n_today',(select count(*) from zhol.requests where player=p and kind='deed' and (created_at at time zone 'Asia/Almaty')::date=zhol._day()),
    'en',jsonb_build_object('ok',en_ok,'n',en_n,'lvl',zhol._lvl(age),'lang',en_lang,'learned',(select count(*) from zhol.en_words where player=p and last_ok and lang='en'),'kk_learned',(select count(*) from zhol.en_words where player=p and last_ok and lang='kk')),
    'today_km',coalesce((select round(km,1) from zhol.daily where player=p and day=zhol._day()),0),
    'today_tokens',coalesce((select tokens from zhol.daily where player=p and day=zhol._day()),0),
    'today_counters',coalesce((select counters from zhol.daily where player=p and day=zhol._day()),'{}'::jsonb),
    'week_km',coalesce((select round(sum(km),1) from zhol.daily where player=p and day>=date_trunc('week',zhol._day())::date),0))
  from zhol.players pl where id=p $function$;


create or replace function zhol._auth(p text, code text) returns text language plpgsql as $$
declare r zhol.players;
begin
  select * into r from zhol.players where id=p for update;
  if not found then return 'no_player'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if code is null or extensions.crypt(code, r.code_hash) <> r.code_hash then
    if r.fails+1 >= 5 then update zhol.players set fails=0, locked_until=now()+interval '5 minutes' where id=p;
    else update zhol.players set fails=r.fails+1 where id=p; end if;
    return 'bad_code';
  end if;
  if r.fails>0 then update zhol.players set fails=0 where id=p; end if;
  return 'ok';
end $$;
revoke all on function zhol._auth(text,text) from public, anon, authenticated;

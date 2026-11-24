-- 전용 신규 Supabase Free 프로젝트, 관리자 포함 9명 생성 후 실행. 관리자 이메일 수정.
begin;
create table public.study_members(id uuid primary key references auth.users(id), role text not null check(role in ('admin','member')), name text not null);
do $$declare admin_email text := 'CHANGE_ADMIN_EMAIL@example.com'; begin
 if (select count(*) from auth.users) <> 9 or not exists(select 1 from auth.users where lower(email)=lower(admin_email)) then raise exception '9개 계정과 관리자 이메일을 확인하세요'; end if;
 insert into public.study_members select id,case when lower(email)=lower(admin_email) then 'admin' else 'member' end,case when lower(email)=lower(admin_email) then '관리자' else coalesce(nullif(raw_user_meta_data->>'name',''),split_part(email,'@',1)) end from auth.users;
end$$;
create table public.study_reports(id uuid primary key,owner uuid not null references public.study_members(id),name text not null,mode text not null,created timestamptz not null default now(),consent boolean not null check(consent),status text not null default 'pending' check(status in ('pending','ready','deleting')),audio_state text not null default 'retained' check(audio_state in ('retained','deleting','deleted')),clips jsonb not null,pdf_bytes bigint not null check(pdf_bytes>=0),audio_bytes bigint not null check(audio_bytes>=0),deletion_requested boolean not null default false);
alter table public.study_members enable row level security;
alter table public.study_reports enable row level security;
revoke all on public.study_members,public.study_reports from anon,authenticated;
grant select on public.study_members,public.study_reports to authenticated;
grant all on public.study_members,public.study_reports to service_role;
create policy self_read on public.study_members for select to authenticated using(id=auth.uid());
create function public.study_admin() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.study_members where id=auth.uid() and role='admin')$$;
revoke all on function public.study_admin() from public; grant execute on function public.study_admin() to authenticated;
create policy reports_read on public.study_reports for select to authenticated using(owner=auth.uid() or public.study_admin());
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values ('study-pdfs','study-pdfs',false,4194304,array['application/pdf']),('study-audio','study-audio',false,2097152,array['audio/webm','audio/mp4','audio/ogg','audio/wav']);
-- 사용자에게 쓰기/삭제 권한 없음. Edge Function만 service_role로 저장.
create policy study_read on storage.objects for select to authenticated using(bucket_id in ('study-pdfs','study-audio') and exists(select 1 from public.study_reports r where r.status='ready' and (storage.foldername(storage.objects.name))[1]=r.owner::text and (storage.foldername(storage.objects.name))[2]=r.id::text and ((bucket_id='study-pdfs' and (r.owner=auth.uid() or public.study_admin())) or (bucket_id='study-audio' and r.audio_state='retained' and public.study_admin()))));
-- 실제 파일과 예약량 중 큰 값을 사용하지 않고, 예약량 + 미등록 객체를 합산. 전용 프로젝트 권장.
create function public.study_usage() returns bigint language sql security definer set search_path='' as $$
 select coalesce((select sum(pdf_bytes+audio_bytes) from public.study_reports),0)::bigint + coalesce((select sum(coalesce((metadata->>'size')::bigint,0)) from storage.objects o where not exists(select 1 from public.study_reports r where o.bucket_id in ('study-pdfs','study-audio') and (storage.foldername(o.name))[1]=r.owner::text and (storage.foldername(o.name))[2]=r.id::text)),0)::bigint
$$;
-- 모든 신규 제출은 동일 advisory transaction lock 안에서 공간 예약. 삭제 중/미완료도 사용량에 포함.
create function public.study_reserve(p_id uuid,p_owner uuid,p_name text,p_mode text,p_clips jsonb,p_pdf bigint,p_audio bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.study_reports%rowtype; begin
 perform pg_advisory_xact_lock(734891);
 if p_pdf<1 or p_pdf>4194304 or p_audio<1 or p_audio>16777216 then raise exception 'invalid size'; end if;
 if exists(select 1 from public.study_reports where id=p_id) then raise exception 'duplicate id'; end if;
 if public.study_usage()+p_pdf+p_audio <=800000000 then
 insert into public.study_reports(id,owner,name,mode,consent,clips,pdf_bytes,audio_bytes) values(p_id,p_owner,p_name,p_mode,true,p_clips,p_pdf,p_audio);return jsonb_build_object('action','reserved'); end if;
 select * into r from public.study_reports where status='ready' and audio_state='retained' and audio_bytes>0 order by created,id limit 1 for update;
 if found then update public.study_reports set audio_state='deleting' where id=r.id;return jsonb_build_object('action','audio','report',to_jsonb(r));end if;
 -- 다른 요청에서 녹음을 삭제하고 있으면 PDF 삭제보다 재시도를 우선.
 if exists(select 1 from public.study_reports where audio_state='deleting' or status='deleting') then return jsonb_build_object('action','wait');end if;
 select * into r from public.study_reports where status='ready' and audio_state='deleted' order by created,id limit 1 for update;
 if found then update public.study_reports set status='deleting' where id=r.id;return jsonb_build_object('action','all','report',to_jsonb(r));end if;
 return jsonb_build_object('action','full');
end$$;
create function public.study_claim_delete(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare r public.study_reports%rowtype;begin
 perform pg_advisory_xact_lock(734891);
 select * into r from public.study_reports where id=p_id for update;
 if not found then raise exception 'not found';end if;
 if r.status='pending' and r.created>now()-interval '10 minutes' then raise exception 'upload pending; retry in 10 minutes';end if;
 if r.audio_state='deleting' or r.status='deleting' then raise exception 'deletion already in progress; inspect in dashboard if stuck';end if;
 update public.study_reports set status='deleting' where id=p_id;return to_jsonb(r);
end$$;
revoke all on function public.study_usage(),public.study_reserve(uuid,uuid,text,text,jsonb,bigint,bigint),public.study_claim_delete(uuid) from public,anon,authenticated;
grant execute on function public.study_usage(),public.study_reserve(uuid,uuid,text,text,jsonb,bigint,bigint),public.study_claim_delete(uuid) to service_role;
commit;

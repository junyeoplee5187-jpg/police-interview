import { createClient } from 'npm:@supabase/supabase-js@2';
const url=Deno.env.get('SUPABASE_URL')!;
const db=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store'};
function reply(data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json'}})}
function checked<T>(r:{data:T,error:any}):T{if(r.error)throw Error(r.error.message);return r.data}
const path=(r:any,file:string)=>`${r.owner}/${r.id}/${file}`;
async function remove(r:any,all:boolean){
 const files=r.clips.map((c:any)=>path(r,c.file));
 if(files.length)checked(await db.storage.from('study-audio').remove(files));
 if(all){checked(await db.storage.from('study-pdfs').remove([path(r,'report.pdf')]));checked(await db.from('study_reports').delete().eq('id',r.id));}
 else checked(await db.from('study_reports').update({audio_state:'deleted',audio_bytes:0}).eq('id',r.id));
}
Deno.serve(async req=>{if(req.method==='OPTIONS')return new Response(null,{headers});if(req.method!=='POST')return reply({error:'method'},405);
 try{
 const token=req.headers.get('Authorization')?.replace(/^Bearer\s+/i,'');if(!token)return reply({error:'로그인 필요'},401);
 const auth=await db.auth.getUser(token);if(auth.error||!auth.data.user)return reply({error:'로그인 만료'},401);
 const owner=auth.data.user.id;const m=checked(await db.from('study_members').select('*').eq('id',owner).maybeSingle());if(!m)return reply({error:'조원 전용'},403);
 const ct=req.headers.get('content-type')||'';
 if(ct.includes('application/json')){
 const b=await req.json();
 if(b.action==='usage'){if(m.role!=='admin')return reply({error:'관리자 전용'},403);return reply({bytes:checked(await db.rpc('study_usage'))});}
 if(b.action==='delete'){
 if(m.role!=='admin'){checked(await db.from('study_reports').update({deletion_requested:true}).eq('id',b.id).eq('owner',owner));return reply({ok:true});}
 const r=checked(await db.rpc('study_claim_delete',{p_id:b.id}));await remove(r,true);return reply({ok:true});}
 return reply({error:'unknown action'},400);
 }
 if(!ct.includes('multipart/form-data'))return reply({error:'invalid content type'},400);
 const length=Number(req.headers.get('content-length')||0);if(length>22*1024*1024)return reply({error:'제출 크기 제한'},413);
 const form=await req.formData();const meta=JSON.parse(String(form.get('meta')));const pdf=form.get('pdf');
 if(meta.consent!==true||typeof meta.name!=='string'||meta.name.trim().length<1||meta.name.length>30||!['혼합','경험·인성','상황','압박'].includes(meta.mode)||!(pdf instanceof File)||pdf.type!=='application/pdf'||pdf.size<5||pdf.size>4194304||!Array.isArray(meta.clips)||meta.clips.length<1||meta.clips.length>8)return reply({error:'제출 정보 오류'},400);
 if(new TextDecoder().decode(await pdf.slice(0,5).arrayBuffer())!=='%PDF-')return reply({error:'PDF 파일 오류'},400);
 const files=[];const clips=[];let bytes=0;const types:Record<string,string>={'audio/webm':'webm','audio/mp4':'m4a','audio/ogg':'ogg','audio/wav':'wav'};
 for(let i=0;i<meta.clips.length;i++){const f=form.get('audio'+i);if(!(f instanceof File)||f.size<1||f.size>2097152||!types[f.type.split(';')[0]])return reply({error:'녹음 파일 오류'},400);const mime=f.type.split(';')[0];const file=`answer-${i+1}.${types[mime]}`;files.push({f,mime,file});clips.push({turn:i+1,file,bytes:f.size});bytes+=f.size;}
 const id=crypto.randomUUID();const r={id,owner,clips};let reserved=false;
 for(let attempt=0;attempt<150;attempt++){
 const plan=checked(await db.rpc('study_reserve',{p_id:id,p_owner:owner,p_name:meta.name.trim(),p_mode:meta.mode,p_clips:clips,p_pdf:pdf.size,p_audio:bytes}));
 if(plan.action==='reserved'){reserved=true;break;}
 if(plan.action==='audio'||plan.action==='all'){await remove(plan.report,plan.action==='all');continue;}
 if(plan.action==='wait'){return reply({error:'저장공간 정리 중입니다. 잠시 후 다시 제출하세요.'},409);}
 return reply({error:'무료 저장 공간 부족: 관리자에게 문의하세요.'},507);
 }
 if(!reserved)return reply({error:'저장 공간 정리 한도 초과. 다시 제출하세요.'},507);
 // 오류가 나면 예약을 함부로 해제하지 않는다. 관리자 화면에서 10분 후 정리 가능.
 checked(await db.storage.from('study-pdfs').upload(path(r,'report.pdf'),pdf,{contentType:'application/pdf',upsert:false}));
 for(const a of files)checked(await db.storage.from('study-audio').upload(path(r,a.file),a.f,{contentType:a.mime,upsert:false}));
 checked(await db.from('study_reports').update({status:'ready'}).eq('id',id));return reply({id});
 }catch(e){console.error(String(e));return reply({error:'처리 실패: 저장 상태를 관리자 화면에서 확인하세요.'},500);}
});

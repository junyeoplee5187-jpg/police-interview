from playwright.sync_api import sync_playwright
from pathlib import Path
import subprocess, tempfile, shutil, json, time, sys
import fitz
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    dst=Path(tmp)/'site';shutil.copytree(root/'site',dst)
    (dst/'config.js').write_text("window.STUDY_CONFIG={url:'http://127.0.0.1:18765',key:'test-key'};")
    p=subprocess.Popen([sys.executable,'-m','http.server','18765','--bind','127.0.0.1','--directory',str(dst)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
      time.sleep(.4)
      with sync_playwright() as w:
        browser=w.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox','--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream','--autoplay-policy=no-user-gesture-required'])
        ctx=browser.new_context(permissions=['microphone'],accept_downloads=True);page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        stored=[]; actor=['member']; payload=[]
        def route(r):
          url=r.request.url
          def reply(x,status=200):r.fulfill(status=status,content_type='application/json',body=json.dumps(x,ensure_ascii=False))
          if '/auth/v1/token' in url:reply({'access_token':'fake-'+actor[0]})
          elif '/study_members?' in url:reply([{'id':actor[0],'role':actor[0],'name':'시험 사용자'}])
          elif '/study_reports?' in url:reply(stored)
          elif '/functions/v1/study-submit' in url:
            if 'multipart/form-data' in r.request.headers.get('content-type',''):
              body=r.request.post_data_buffer;payload.append(body); stored.append({'id':'test-id','owner':'member','name':'시험 사용자','mode':'혼합','created':'2026-11-25T00:00:00Z','status':'ready','audio_state':'retained','clips':[{'turn':1,'file':'answer-1.webm'}]});reply({'id':'test-id'})
            else:
              b=r.request.post_data_json;reply({'bytes':12345} if b['action']=='usage' else {'ok':True})
          elif '/storage/v1/' in url:r.fulfill(status=200,body=b'fake audio',content_type='audio/webm')
          elif '/auth/v1/logout' in url:r.fulfill(status=204)
          else:
            from urllib.parse import urlparse
            import mimetypes
            f=dst/(urlparse(url).path.lstrip('/') or 'index.html');r.fulfill(status=200,body=f.read_bytes() if f.is_file() else b'',content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
        html=(dst/'index.html').read_text()
        for fn in ['config.js','questions.js','report.js','cloud.js']:
          html=html.replace(f'<script src="{fn}"></script>','<script>'+ (dst/fn).read_text()+'</script>')
        mock="""<script>let actor='member',stored=[],pdfData=null,audioCount=0;window.fetch=async (url,opts={})=>{let data;if(url.includes('/auth/v1/token'))data={access_token:'fake'};else if(url.includes('/study_members?'))data=[{id:actor,role:actor,name:'시험 사용자'}];else if(url.includes('/study_reports?'))data=stored;else if(url.includes('/functions/v1/')){if(opts.body instanceof FormData){pdfData=await opts.body.get('pdf').arrayBuffer();audioCount=[...opts.body.keys()].filter(k=>k.startsWith('audio')).length;stored=[{id:'test-id',owner:'member',name:'시험 사용자',mode:'혼합',created:'2026-11-25T00:00:00Z',status:'ready',audio_state:'retained',clips:[{turn:1,file:'answer-1.webm'}]}];data={id:'test-id'}}else data={bytes:12345};}else if(url.includes('/storage/v1/'))return new Response(new Blob(['fake audio'],{type:'audio/webm'}));else data={};return new Response(JSON.stringify(data),{headers:{'Content-Type':'application/json'}})};Object.defineProperty(navigator,'mediaDevices',{value:{getUserMedia:async()=>{const ac=new AudioContext();const dest=ac.createMediaStreamDestination();const osc=ac.createOscillator();osc.connect(dest);osc.start();await ac.resume();return dest.stream;}}});</script>"""
        page.set_content(html.replace('<script>window.STUDY_CONFIG',mock+'<script>window.STUDY_CONFIG',1));page.fill('#uid','test@example.com');page.fill('#pw','fake-password');page.locator('#loginForm button').click();page.wait_for_selector('#home',state='visible')
        page.click('#start');assert '동의' in page.inner_text('#msg');page.check('#consent');page.click('#start');page.wait_for_selector('#exam',state='visible');assert page.inner_text('#progress').startswith('1 / 4');
        for i in range(4):
          page.click('#record');page.wait_for_timeout(700);page.click('#stop');page.wait_for_function("!document.getElementById('next').disabled");page.fill('#answer','당시 상황에서 동료와 협력하고 확인한 뒤 보고했습니다. 국민 안전과 절차를 지키고 재발 방지를 위해 기록했습니다.');page.click('#next')
        page.wait_for_selector('#home',state='visible');page.wait_for_function("document.getElementById('msg').textContent.includes('제출 완료')");assert page.evaluate('audioCount')==4;assert page.get_by_text('답변 녹음 보기').count()==0;assert page.get_by_text('PDF 다운로드').count()==1
        pdf=bytes(page.evaluate('Array.from(new Uint8Array(pdfData))'));doc=fitz.open(stream=pdf,filetype='pdf');assert len(doc)>=1;assert doc[0].get_pixmap().width>0
        (root.parent/'police_cloud_test_report.pdf').write_bytes(pdf)
        page.evaluate("actor='admin'; login({id:'admin',role:'admin',name:'관리자'})");page.get_by_text('답변 녹음 보기').click();page.get_by_text('녹음 불러오기').click();page.wait_for_function("document.querySelector('audio')?.src.startsWith('blob:')");assert '800 MB' in page.inner_text('#usage');assert not errors,errors
        browser.close();print('PASS: consent, 4 questions, virtual microphone capture, multipart upload, PDF rendering, member/admin UI, audio retrieval (mock cloud).')
    finally:p.terminate();p.wait()

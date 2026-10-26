import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const {webkit} = await import(process.env.XTEND_PLAYWRIGHT_MODULE ?? 'playwright');
const browser=await webkit.launch({headless:true});
try {
 const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
 const html=`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"/></head><body>
 <div data-testid="ScrollSnap-List" role="tablist" style="width:390px;height:50px">
 <button role="tab" aria-selected="true" id="a">For you</button><button role="tab" aria-selected="false" id="b">Following</button></div>
 <main data-testid="primaryColumn"><section id="surface" data-xtend-swipe-surface style="height:500px"><article id="post">Hello</article></section></main>
 <script>
 window.__messages=[];
 window.webkit={messageHandlers:{xtendBetaTab:{postMessage:m=>window.__messages.push(m)}}};
 document.querySelectorAll('[role=tab]').forEach(tab=>tab.addEventListener('click',()=>{
 document.querySelectorAll('[role=tab]').forEach(t=>t.setAttribute('aria-selected',String(t===tab)));
 }));
 </script></body></html>`;
 await page.route('https://x.com/home',r=>r.fulfill({body:html,contentType:'text/html',status:200}));
 await page.goto('https://x.com/home');
 await page.addScriptTag({content:readFileSync('Xtend/Resources/xtend-swipe.js','utf8')});
 await page.evaluate(()=>{window.__xtendBetaTabReady=true});
 await page.locator('#b').click();
 let state=await page.evaluate(()=>({messages:window.__messages, selected:document.querySelector('#a').getAttribute('aria-selected')}));
 assert.deepEqual(state.messages,[{action:'switch',target:1}]);
 assert.equal(state.selected,'true','native beta request should avoid X default click');
 await page.evaluate(()=>{
  const post=document.getElementById('post');
  const send=(type,x)=>{const event=new Event(type,{bubbles:true,cancelable:true});const point={clientX:x,clientY:300};
   Object.defineProperties(event,{touches:{value:type==='touchend'?[]:[point]},changedTouches:{value:[point]}});post.dispatchEvent(event);};
  send('touchstart',185);send('touchmove',45);send('touchend',45);
 });
 state=await page.evaluate(()=>({messages:window.__messages, selected:document.querySelector('#a').getAttribute('aria-selected')}));
 assert.deepEqual(state.messages,[{action:'switch',target:1},{action:'switch',target:1}]);
 assert.equal(state.selected,'true');
 await page.evaluate(()=>{window.__xtendBetaTabReady=false});
 await page.locator('#b').click();
 assert.equal(await page.locator('#b').getAttribute('aria-selected'),'true','disabled falls back to X');
 console.log('PASS beta click, swipe bridge, and disabled fallback');
} finally {await browser.close();}

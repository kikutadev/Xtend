// Headless WebKit memory A/B for a synthetic timeline, not a logged-in X test.
// XTEND_PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/measure-webkit-memory.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const {webkit} = await import(process.env.XTEND_PLAYWRIGHT_MODULE ?? 'playwright');
const baseline = readFileSync('.build/before-swipe.js', 'utf8');
const candidate = readFileSync('Xtend/Resources/xtend-swipe.js', 'utf8');
const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;font-family:system-ui} [role=tablist]{position:sticky;top:0;display:flex;height:50px;background:white;z-index:2}
[role=tab]{width:50%} [data-xtend-swipe-surface]{height:620px;overflow:hidden} article{border-bottom:1px solid #ddd;height:125px;padding:6px}</style></head><body>
<div data-testid="ScrollSnap-List" role="tablist"><button role="tab" aria-selected="true" id="a">For you</button><button role="tab" aria-selected="false" id="b">Following</button></div>
<main data-testid="primaryColumn"><div data-xtend-swipe-surface><div id="feed"></div></div></main>
<script>
const feed=document.getElementById('feed'); let active='a';window.__switches=0;
function render(){feed.replaceChildren(...Array.from({length:25},(_,i)=>{const el=document.createElement('article');el.textContent='Timeline '+active+' post '+i+' '+('x'.repeat(240));return el}));}
render();
for(const id of ['a','b'])document.getElementById(id).onclick=()=>{active=id;document.getElementById('a').setAttribute('aria-selected',String(id==='a'));
 document.getElementById('b').setAttribute('aria-selected',String(id==='b'));window.__switches++;setTimeout(render,20);};
</script></body></html>`;
function processMemory() {
  const ps=execFileSync('ps',['-axo','pid=,ppid=,rss=,comm='],{encoding:'utf8'});
  const rows=ps.trim().split('\n').map(line=>{
    const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return m?{pid:+m[1],ppid:+m[2],rssKiB:+m[3],name:m[4]}:null;
  }).filter(Boolean);
  const descendants=new Set([process.pid]);
  let delta=true;
  while(delta){ delta=false; for(const row of rows)if(descendants.has(row.ppid)&&!descendants.has(row.pid)){descendants.add(row.pid);delta=true;} }
  const active=rows.filter(r=>descendants.has(r.pid) && (r.name.includes('Playwright') || r.name.includes('WebKit')));
  let physicalMiB=null;
  let physicalPeakMiB=null;
  if(active.length===1){
    try {
      const output=execFileSync('footprint',['-p',String(active[0].pid),'--noCategories'],{encoding:'utf8'});
      const toMiB=(number,unit)=>+number*(unit==='GB'?1024:unit==='KB'?1/1024:1);
      const match=output.match(/phys_footprint:\s+([\d.]+)\s+(KB|MB|GB)/);
      const peak=output.match(/phys_footprint_peak:\s+([\d.]+)\s+(KB|MB|GB)/);
      if(match)physicalMiB=toMiB(match[1],match[2]);
      if(peak)physicalPeakMiB=toMiB(peak[1],peak[2]);
    } catch { /* some CI/macOS setups restrict footprint */ }
  }
  return {physicalMiB,physicalPeakMiB,rssMiB:Math.round(active.reduce((sum,r)=>sum+r.rssKiB,0)/1024*10)/10, processes:active.map(r=>({pid:r.pid,rssMiB:Math.round(r.rssKiB/1024*10)/10,name:r.name.split('/').at(-1)}))};
}
async function swipe(page, toB){
  await page.evaluate(toB=>{
    const target=document.getElementById('feed');const point=x=>({clientX:x,clientY:250});
    function emit(type,x){const event=new Event(type,{bubbles:true,cancelable:true});Object.defineProperties(event,{
      touches:{value:type==='touchend'?[]:[point(x)]},changedTouches:{value:[point(x)]}});target.dispatchEvent(event);}
    emit('touchstart',toB?185:45); emit('touchmove',toB?45:185);emit('touchend',toB?45:185);
  },toB);
}
const samples=[];
for(const label of ['before','after','after','before','before','after']){
  const browser=await webkit.launch({headless:true});
  const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
  const page=await context.newPage();
  await page.route('https://x.com/home',route=>route.fulfill({body:html,contentType:'text/html',status:200}));
  await page.goto('https://x.com/home');
  await page.addScriptTag({content:label==='before'?baseline:candidate});
  await page.waitForTimeout(500);
  const idle=processMemory();
  let max=idle.rssMiB;
  for(let j=0;j<24;j++){
    await swipe(page,j%2===0);
    await page.waitForTimeout(230);
    if(j%4===0){ const rss=processMemory().rssMiB;max=Math.max(max,rss);}
  }
  await page.waitForTimeout(1200);
  const settled=processMemory();
  const count=await page.evaluate(()=>window.__switches);
  assert.equal(count,24,`${label} expected 24 tab switches, got ${count}`);
  const result={label,run:samples.length+1, idleRSSMiB:idle.rssMiB, after24RSSMiB:settled.rssMiB, sampledMaxRSSMiB:Math.max(max,settled.rssMiB), idlePhysicalMiB:idle.physicalMiB, after24PhysicalMiB:settled.physicalMiB, physPeakMiB:settled.physicalPeakMiB, processes:settled.processes};
  samples.push(result);
  console.log(JSON.stringify(result));
  await browser.close();
}
mkdirSync('.build',{recursive:true});
writeFileSync('.build/webkit-memory-ab.json',JSON.stringify(samples,null,2));
for(const label of ['before','after']){
  const a=samples.filter(x=>x.label===label);
  const median=values=>values.sort((x,y)=>x-y)[Math.floor(values.length/2)];
  console.log('SUMMARY '+JSON.stringify({label,runs:a.length,medianIdleMiB:median(a.map(x=>x.idleRSSMiB)),medianSettledMiB:median(a.map(x=>x.after24RSSMiB)),medianObservedMaxMiB:median(a.map(x=>x.sampledMaxRSSMiB)),medianIdlePhysicalMiB:median(a.map(x=>x.idlePhysicalMiB)),medianSettledPhysicalMiB:median(a.map(x=>x.after24PhysicalMiB)),medianPhysicalPeakMiB:median(a.map(x=>x.physPeakMiB))}));
}

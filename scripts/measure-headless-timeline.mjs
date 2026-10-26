// Headless, real-browser DOM benchmark; X-shaped fixture, never calls X APIs.
// Usage: node scripts/measure-headless-timeline.mjs [web|chromium]
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
// Optional QA dependency: install Playwright or point to its local module.
const playwrightModule = process.env.XTEND_PLAYWRIGHT_MODULE ?? 'playwright';
let browsers;
try { browsers = await import(playwrightModule); }
catch (error) {
  console.error('Headless QA requires Playwright and browser binaries. Set XTEND_PLAYWRIGHT_MODULE to an installed Playwright index.mjs.');
  throw error;
}
const { webkit, chromium } = browsers;

const browserKind = process.argv[2] === 'chromium' ? 'chromium' : 'webkit';
const engine = browserKind === 'webkit' ? webkit : chromium;
const browser = await engine.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
const page = await context.newPage();
page.on('pageerror', e => { console.error('PAGE ERROR', e.message); process.exitCode = 1; });
const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"/>
<style>body { margin:0; } [role=tablist] {display:flex; height:50px; position:sticky; top:0; background:#fff; z-index:5}
[role=tab]{ width:50%; height:50px; } [data-testid=primaryColumn] {width:100%;} [data-xtend-swipe-surface] {height:450px; background:#eef;}
#entry {height:200px; padding:12px;}</style></head><body>
<div data-testid="ScrollSnap-List" role="tablist"><button role="tab" id="for-you" aria-selected="true">For you</button><button role="tab" id="following" aria-selected="false">Following</button></div>
<main data-testid="primaryColumn"><section data-xtend-swipe-surface><article id="entry">For you timeline</article></section></main>
<script>
window.__clicks=[]; window.__paints=[];
for (const [id, other, label] of [
  ['following','for-you','Following timeline'],['for-you','following','For you timeline']]) {
  document.getElementById(id).addEventListener('click', () => {
    window.__clicks.push(performance.now());
    document.getElementById(other).setAttribute('aria-selected','false');
    document.getElementById(id).setAttribute('aria-selected','true');
    setTimeout(() => { document.getElementById('entry').textContent=label;
      requestAnimationFrame(() => window.__paints.push(performance.now())); }, 90);
  });
}
</script></body></html>`;
await page.route('https://x.com/home', route => route.fulfill({ status:200, contentType:'text/html; charset=utf-8', body:html }));
const sources = {
  before: readFileSync('.build/before-swipe.js', 'utf8'),
  after: readFileSync('Xtend/Resources/xtend-swipe.js', 'utf8'),
};
const samples = [];
const shots = new Set();
for (const label of ['before', 'after']) {
  for (let i = 0; i < 8; i++) {
    await page.goto('https://x.com/home');
    await page.addScriptTag({ content: sources[label] });
    await page.evaluate(() => {
      const target = document.getElementById('entry');
      const touch = (type,x) => {
        const point = { clientX:x, clientY:300 };
        const event = new Event(type,{ bubbles:true,cancelable:true });
        Object.defineProperties(event, {
          touches: {value:type === 'touchend' || type === 'touchcancel' ? [] : [point]},
          changedTouches: {value:[point]},
        });
        target.dispatchEvent(event);
      };
      touch('touchstart',185);
      touch('touchmove',45);
      window.__endAt = performance.now();
      touch('touchend',45);
    });
    await page.waitForTimeout(300);
    const result = await page.evaluate(() => ({
      viewTransitions: typeof document.startViewTransition === 'function',
      clickDelay: Math.round(((window.__clicks[0] ?? NaN)-window.__endAt)*10)/10,
      paintDelay: Math.round(((window.__paints[0] ?? NaN)-window.__endAt)*10)/10,
      selected:document.getElementById('following').getAttribute('aria-selected'),
      text:document.getElementById('entry').textContent,
      transforms:document.querySelector('[data-xtend-swipe-surface]').style.transform,
      viewTransitionName:document.querySelector('[data-xtend-swipe-surface]').style.viewTransitionName,
      styleLeaks: [...document.querySelectorAll('style')].filter(s=>s.textContent.includes('xtend-swipe-exit')).length,
    }));
    assert.equal(result.selected,'true',`${label} run ${i} selected`);
    assert.equal(result.text,'Following timeline',`${label} run ${i} content`);
    assert.equal(result.viewTransitionName, '', `${label} run ${i} transition styles restored`);
    assert.equal(result.styleLeaks, 0, `${label} run ${i} transition CSS removed`);
    if (!shots.has(label)) {
      mkdirSync('.build', { recursive:true });
      await page.screenshot({path:`.build/headless-${browserKind}-${label}.png`});
      shots.add(label);
    }
    samples.push({label,run:i,...result});
  }
}
// Reuse the same page and loaded timeline. A second swipe should return
// through X's own tab handlers rather than spawning a new web view.
await page.goto('https://x.com/home');
await page.addScriptTag({content:sources.after});
const swipe = async (from, to, cancel = false) => page.evaluate(({from,to,cancel})=> {
  const target=document.getElementById('entry');
  const emit = (type,x) => {
    const point={clientX:x,clientY:300};
    const event=new Event(type,{bubbles:true,cancelable:true});
    Object.defineProperties(event, {touches:{value: type==='touchcancel'||type==='touchend'?[]:[point]},changedTouches:{value:[point]}});
    target.dispatchEvent(event);
  };
  emit('touchstart',from);
  emit('touchmove',to);
  emit(cancel?'touchcancel':'touchend',to);
}, {from,to,cancel});
await swipe(185,45);
await page.waitForTimeout(340);
await swipe(185,325);
await page.waitForTimeout(380);
let roundTrip=await page.evaluate(() => ({
  count:window.__clicks.length,
  tab:document.getElementById('for-you').getAttribute('aria-selected'),
  text:document.getElementById('entry').textContent,
  transitionName:document.querySelector('[data-xtend-swipe-surface]').style.viewTransitionName,
}));
assert.deepEqual(roundTrip,{count:2,tab:'true',text:'For you timeline',transitionName:''});
await swipe(185,45,true);
await page.waitForTimeout(200);
assert.equal(await page.evaluate(()=>window.__clicks.length),2,'cancel must preserve selected tab');
await swipe(185,170);
await page.waitForTimeout(200);
assert.equal(await page.evaluate(()=>window.__clicks.length),2,'short swipe must preserve selected tab');
console.log(`PASS ${browserKind} headless round-trip and cancellation`);

const median = numbers => {
  const sorted=numbers.slice().sort((a,b)=>a-b);
  return (sorted[3] + sorted[4])/2;
};
for (const label of ['before','after']) {
  const data=samples.filter(s=>s.label===label);
  console.log(JSON.stringify({browser:browserKind,version:label,
    viewTransitions:data[0].viewTransitions,
    runs:data.length,
    medianClickDelayMs:median(data.map(s=>s.clickDelay)),
    medianPaintDelayMs:median(data.map(s=>s.paintDelay)),
    clickDelays:data.map(s=>s.clickDelay),
  }));
}
mkdirSync('.build',{recursive:true});
writeFileSync(`.build/headless-${browserKind}-timings.json`,JSON.stringify(samples,null,2));
await browser.close();

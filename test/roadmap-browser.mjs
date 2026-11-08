#!/usr/bin/env node
// Documentation-only browser verification. Never part of the compiler/runtime.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync,writeFileSync,mkdirSync,readdirSync,existsSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {homedir} from 'node:os';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const require=createRequire(import.meta.url),{chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const root=fileURLToPath(new URL('../',import.meta.url)),url=pathToFileURL(join(root,'docs/roadmap.html')).href;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const output=join(root,'out/roadmap-preview');mkdirSync(output,{recursive:true});
const cache=join(homedir(),'.cache/ms-playwright');
let executable=process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
if(!executable&&existsSync(cache))for(const dir of readdirSync(cache).filter(s=>s.startsWith('chromium_headless_shell-')).sort((a,b)=>Number(b.split('-').at(-1))-Number(a.split('-').at(-1)))){
 const candidate=join(cache,dir,'chrome-headless-shell-linux64/chrome-headless-shell');if(existsSync(candidate)){executable=candidate;break;}
}
const browser=await chromium.launch({headless:true,...(executable?{executablePath:executable}:{})});
const observations=[],errors=[],requests=[];
function watch(page){page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>requests.push(request.url()));}
function verified(name,detail={}){observations.push({check:name,passed:true,...detail});}
try{
 const context=await browser.newContext({viewport:{width:1440,height:1050},reducedMotion:'reduce'}),page=await context.newPage();watch(page);
 await page.goto(url);await page.waitForSelector('.step');
 assert.equal(await page.locator('.step').count(),8);assert.equal(await page.locator('.step[open]').count(),1);assert.equal(await page.locator('#full-size').getAttribute('open'),'');
 assert.equal(await page.locator('#percent').textContent(),'70');assert.equal(await page.locator('#tests').textContent(),'631');assert.equal(await page.locator('#upstream').textContent(),'297');assert.equal(await page.locator('#examples').textContent(),'16');assert.equal(await page.locator('#cli-bytes').textContent(),'582,442');
 verified('eight stages, evidence-derived metrics, subjective estimate and next-step default');
 await page.getByRole('button',{name:'Core milestone',exact:true}).click();assert.equal(await page.locator('.step:visible').count(),4);
 await page.getByRole('button',{name:'Beyond self-hosting',exact:true}).click();assert.equal(await page.locator('.step:visible').count(),4);
 await page.getByRole('button',{name:'All eight',exact:true}).click();await page.getByRole('searchbox').fill('ARM64');assert.equal(await page.locator('.step:visible').count(),1);assert.equal(await page.locator('.step:visible').getAttribute('id'),'targets');
 await page.getByRole('searchbox').fill('nothing-matches-this-criterion');assert.equal(await page.locator('#empty').isVisible(),true);
 await page.getByRole('button',{name:'Open the reliability spec →'}).click();assert.equal(await page.getByRole('searchbox').inputValue(),'');assert.equal(await page.locator('.step:visible').count(),8);
 verified('core/extension filters, full-spec search, no-results and next-focus navigation');
 const details=page.locator('#full-size');await details.getByRole('tab',{name:'Spec',exact:true}).focus();await page.keyboard.press('ArrowRight');assert.equal(await details.getByRole('tab',{name:'Acceptance',exact:true}).getAttribute('aria-selected'),'true');assert.equal(await details.getByRole('tabpanel',{name:'Acceptance',exact:true}).isVisible(),true);
 await page.keyboard.press('End');assert.equal(await details.getByRole('tab',{name:'Evidence & references',exact:true}).getAttribute('aria-selected'),'true');await page.keyboard.press('Home');assert.equal(await details.getByRole('tab',{name:'Spec',exact:true}).getAttribute('aria-selected'),'true');
 verified('keyboard tab navigation and ARIA panel/selection behavior');
 await details.getByRole('tab',{name:'Acceptance',exact:true}).click();await page.locator('#full-size-1').check();
 const note='<img src=x onerror="window.unexpectedReviewExecution=1"> inspect the real stack frontier';await page.locator('#full-size-notes').fill(note);
 assert.match(await page.locator('#full-size-review-count').textContent(),/1 \/ 4/);assert.equal(await page.locator('#percent').textContent(),'70');assert.equal(await page.evaluate(()=>window.unexpectedReviewExecution),undefined);
 await page.reload();await page.locator('#full-size').getByRole('tab',{name:'Acceptance',exact:true}).click();assert.equal(await page.locator('#full-size-1').isChecked(),true);assert.equal(await page.locator('#full-size-notes').inputValue(),note);assert.equal(await page.locator('#percent').textContent(),'70');
 verified('local review persistence; note text remains inert and never changes verified progress');
 const download=page.waitForEvent('download');await page.getByRole('button',{name:'Export my review ↓'}).click();const saved=await download;const exportedPath=join(output,'review.json');await saved.saveAs(exportedPath);const exported=JSON.parse(readFileSync(exportedPath,'utf8'));assert.deepEqual(exported.checks,['full-size-1']);assert.equal(exported.notes['full-size'],note);assert.match(exported.kind,/personal review/);assert.equal('estimate' in exported,false);assert.equal('status' in exported,false);
 verified('export contains personal annotations and provenance, not fabricated verification/status');
 await page.locator('#full-size').getByRole('tab',{name:'Spec',exact:true}).click();await page.evaluate(()=>window.scrollTo(0,0));await page.screenshot({path:join(output,'desktop.png')});
 const mobileContext=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:1,isMobile:true,hasTouch:true,reducedMotion:'reduce'}),mobile=await mobileContext.newPage();watch(mobile);await mobile.goto(url);
 for(const width of [320,390,768]){await mobile.setViewportSize({width,height:844});assert.equal(await mobile.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'overflow at '+width);}
 await mobile.setViewportSize({width:390,height:844});await mobile.screenshot({path:join(output,'mobile.png')});await mobile.locator('#full-size').getByRole('tab',{name:'Acceptance',exact:true}).tap();await mobile.locator('#full-size-2').check();assert.equal(await mobile.locator('#full-size-2').isChecked(),true);
 verified('320/390/768px layouts have no horizontal overflow; touch review works');
 const fallbackContext=await browser.newContext(),fallback=await fallbackContext.newPage();watch(fallback);await fallback.goto(url);await fallback.evaluate(()=>localStorage.setItem('gleam-in-gleam.roadmap.review.v1','{broken'));await fallback.reload();assert.equal(await fallback.locator('#storage-warning').isVisible(),true);assert.equal(await fallback.locator('.step').count(),8);
 verified('malformed saved review recovers with a visible warning');
 const blockedContext=await browser.newContext();await blockedContext.addInitScript(()=>Object.defineProperty(window,'localStorage',{get(){throw new DOMException('Storage disabled','SecurityError');}}));const blocked=await blockedContext.newPage();watch(blocked);await blocked.goto(url);assert.equal(await blocked.locator('#storage-warning').isVisible(),true);await blocked.locator('#full-size').getByRole('tab',{name:'Acceptance',exact:true}).click();await blocked.locator('#full-size-1').check();assert.equal(await blocked.locator('#full-size-1').isChecked(),true);
 const blockedDownload=blocked.waitForEvent('download');await blocked.getByRole('button',{name:'Export my review ↓'}).click();const blockedSaved=await blockedDownload;const blockedPath=join(output,'storage-blocked-review.json');await blockedSaved.saveAs(blockedPath);assert.deepEqual(JSON.parse(readFileSync(blockedPath,'utf8')).checks,['full-size-1']);
 verified('storage-denied mode still supports in-memory review and export');
 const staticContext=await browser.newContext({javaScriptEnabled:false}),staticPage=await staticContext.newPage();await staticPage.goto(url);assert.equal(await staticPage.locator('noscript').isVisible(),true);assert.ok(await staticPage.getByRole('link',{name:'text roadmap',exact:true}).count());verified('no-JavaScript fallback links to the complete text roadmap');
 assert.deepEqual(errors,[]);assert.deepEqual(requests.filter(u=>/^https?:/.test(u)),[]);verified('no browser script errors and no external HTTP requests');
 const paths=['docs/roadmap.html','docs/roadmap.template.html','docs/roadmap.json','tools/render_roadmap.py','FULL_SIZE_RELIABILITY_SPEC.md','test/roadmap-browser.mjs'];
 const receipt={schema:'gleam-in-gleam.roadmap-ui-verification/1',observedAt:new Date().toISOString(),browser:await browser.version(),pageMode:'offline file URL',observations,sourceSHA256:Object.fromEntries(paths.map(p=>[p,sha(readFileSync(join(root,p)))])),screenshots:{desktop:{path:'out/roadmap-preview/desktop.png',sha256:sha(readFileSync(join(output,'desktop.png')))},mobile:{path:'out/roadmap-preview/mobile.png',sha256:sha(readFileSync(join(output,'mobile.png')))}}};
 if(process.argv[2]){const target=join(root,process.argv[2]);mkdirSync(dirname(target),{recursive:true});writeFileSync(target,JSON.stringify(receipt,null,2)+'\n');}
 console.log(JSON.stringify({checks:observations.length,passed:true,browser:receipt.browser,externalRequests:0,receipt:process.argv[2]||null},null,2));
}finally{await browser.close();}

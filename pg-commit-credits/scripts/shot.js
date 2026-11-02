const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();
for (const [w,s] of [[1200,'light'],[420,'dark']]){const p=await b.newPage({viewport:{width:w,height:900},colorScheme:s});p.on('console',m=>console.log(m.text()));p.on('pageerror',e=>console.log('ERR',e.message));
await p.goto('file://'+process.argv[2]);await p.waitForTimeout(800);await p.screenshot({path:`screenshot-${w}.png`,fullPage:true});console.log(w, await p.evaluate(()=>document.documentElement.scrollWidth));}
await b.close()})()

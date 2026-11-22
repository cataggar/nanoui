// Headless engine capability probe; unavailable adapters are reported explicitly.
import { firefox, webkit } from 'playwright';
import { serve } from './serve.mjs';
const host=await serve();
try{
  for(const [name,type,options]of[
    ['Firefox',firefox,{firefoxUserPrefs:{'dom.webgpu.enabled':true,'dom.webgpu.force-enabled':true,'gfx.webrender.all':true}}],['WebKit',webkit,{}],
  ]){
    let browser;
    try{
      browser=await type.launch({headless:true,...options});const page=await browser.newPage({viewport:{width:420,height:300}});
      await page.goto(host.url);const support=await page.evaluate(async()=>{
        const webgl2=!!document.createElement('canvas').getContext('webgl2');
        if(!navigator.gpu)return{webgpu:false,adapter:false,webgl2};
        const adapter=await navigator.gpu.requestAdapter().catch(()=>null);
        return{webgpu:true,adapter:!!adapter,webgl2};
      });
      if(!support.adapter && !support.webgl2){console.log(name,JSON.stringify(support));continue;}
      await page.goto(host.url+'/index.html');
      await page.waitForFunction(()=>window.nanoui?.exports.nanoui_web_frames()>1,{},{timeout:15000});
      await page.mouse.click(207,185);await page.waitForTimeout(600);
      const result=await page.evaluate(async()=>{await window.nanoui.gpu.check();return{backend:window.nanoui.backend,frames:window.nanoui.exports.nanoui_web_frames(),value:Number(window.nanoui.exports.counter_value())};});
      console.log(name,JSON.stringify({...support,...result}));
      if(result.value!==1)process.exitCode=1;
    }catch(error){console.log(name,JSON.stringify({error:error.message}));process.exitCode=1;}
    finally{await browser?.close();}
  }
}finally{await host.close();}

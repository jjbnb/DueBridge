// Synthetic fixtures only; public school domains test exact request policies.
// Executes the shipped fixed JavaScript with synthetic browser/fetch boundaries.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const source = fs.readFileSync(process.argv[2], 'utf8');
const script = new AsyncFunction('platform','operation','requestURL','requestMethod','requestBody','expectedIdentity','requestID','fetch','localStorage','document','DOMParser','location','AbortController','TextDecoder','setTimeout','clearTimeout','globalThis', source);
let checks = 0;
function verify(v, message) { assert(v, message); checks++; }
function response(text, {type='application/json',status=200, chunks}={}) {
    const bytes = chunks ?? [new TextEncoder().encode(text)]; let i = 0;
    return {status, ok:status>=200&&status<300, redirected:false, headers:{get:n=>n.toLowerCase()==='content-type'?type:null}, body:{getReader:()=>({read:async()=>i<bytes.length?{done:false,value:bytes[i++]}:{done:true}, cancel:async()=>{}})}};
}
async function run({p='mo',op='identity',id='opaque',url='https://mo.zju.edu.cn/pyapi/course',method='GET',body=null, expected='opaque', token='private-token', user='user-no', fetch:handler, htmlID='student', timer}={}) {
    const calls=[]; const storage = {getItem:k=>({token, user_obj_id:id, user_ID:user})[k] ?? null};
    const state = {};
    if (handler?.observe) handler.observe(state);
    const result=await script(p,op,url,method,body,expected,'fixture',async(u,o)=>{calls.push({url:u, options:o});return handler?await handler(u,o,calls.length):response('{"_id":"opaque","user_ID":"user-no"}')},storage,{cookie:'XSRF-TOKEN=private%20xsrf'},class {parseFromString(){return {querySelector:()=>htmlID===null?null:{getAttribute:()=>htmlID,value:htmlID}}}}, {origin:p==='mo'?'https://mo.zju.edu.cn':'https://courses.zju.edu.cn'},AbortController,TextDecoder,timer??setTimeout,clearTimeout,state);
    return {result,calls,state};
}
(async()=>{
    let cancellationState;
    const cancelFetch = async()=>{ verify(cancellationState.__bbDDLAbort.requestID === 'fixture', 'abort handle belongs to this request'); cancellationState.__bbDDLAbort.controller.abort(); throw Error('cancel'); };
    cancelFetch.observe=s=>{cancellationState=s;};
    const cancellation = await run({op:'read', fetch:cancelFetch});
    verify(cancellation.result.error === 'cancelled', 'external abort cancels only this script');
    let value=await run();
    verify(value.result.identity==='opaque', 'identity needs validated server profile');
    verify(value.calls[0].url==='https://mo.zju.edu.cn/pyapi/user/profile/user-no', 'MO profile route uses stored server user number');
    verify(value.calls[0].options.headers.Authorization==='Bearer private-token', 'Bearer remains in JS fetch');
    verify(!JSON.stringify(value.result).includes('private-token'), 'token never returned');
    value = await run({op:'read',fetch:()=>response('{}' + ' '.repeat(8*1024*1024-2))});
    verify(value.result.payload.length===8*1024*1024, 'exact byte limit remains usable');
    value = await run({user:'..'});
    verify(value.calls.length === 0 && value.result.error === 'loginRequired', 'dot profile binding cannot normalize into a different route');
    for(const changes of [{token:null},{id:''},{fetch:()=>response('{"_id":"other"}')},{fetch:()=>response('{}')},{fetch:()=>response('{}',{status:401})},{fetch:()=>response('<html/>',{type:'text/html'})}]){
        value=await run(changes);verify(value.result.error==='loginRequired'||value.result.error==='invalidResponse','missing/changed/unauthenticated identity fails');
    }
    value=await run({op:'read',fetch:()=>response('{"objects":[],"count":0}')});
    verify(value.result.payload==='{"objects":[],"count":0}', 'bounded JSON transported verbatim');
    verify(value.calls[0].options.redirect==='error' && value.calls[0].options.credentials==='same-origin', 'no redirects or credential export');
    for(const changed of [
        {expected:'other'},
        {fetch:()=>response('{}',{status:403})},
        {fetch:()=>response('{}',{status:500})},
        {fetch:()=>response('<html/>',{type:'text/html'})},
        {fetch:()=>({...response('{}'),redirected:true})},
        {fetch:()=>response('{}',{chunks:[new Uint8Array(8*1024*1024),new Uint8Array(1)]})},
        {fetch:()=>response('{}',{chunks:[new Uint8Array([0xff])]})},
        {fetch:()=>{throw Error('PRIVATE ERROR /?token=secret')}},
    ]) {
        value=await run({op:'read',...changed});
        verify(['accountChanged','loginRequired','invalidResponse','budgetExceeded','network'].includes(value.result.error), 'failed read returns only classified error');
        verify(!JSON.stringify(value.result).includes('secret'), 'server error redacted');
    }
    value=await run({p:'learningInZJU',htmlID:'student',fetch:()=>response('<input id="userId" value="student">',{type:'text/html'})});
    verify(value.result.identity==='student' && value.calls[0].url==='https://courses.zju.edu.cn/user/index','xzzd fetches server HTML identity');
    value=await run({p:'learningInZJU',htmlID:null,fetch:()=>response('<html>login</html>',{type:'text/html'})});
    verify(value.result.error==='loginRequired', 'xzzd login HTML with no ID rejected');
    value=await run({p:'learningInZJU',op:'read',url:'https://courses.zju.edu.cn/api/my-courses',method:'POST',body:'{}',fetch:()=>response('{}')});
    verify(value.calls[0].options.headers['X-XSRF-TOKEN']==='private xsrf','read POST sends decoded same-origin XSRF header');
    verify(!JSON.stringify(value.result).includes('xsrf'),'XSRF token never returned');
    value=await run({op:'read',fetch:async(_,o)=>new Promise((_,reject)=>o.signal.addEventListener('abort',()=>reject(Error('abort')))),timer:(f)=>setTimeout(f,1)});
    verify(value.result.error==='timeout', 'fetch timeout aborts and classifies');
    console.log(`PASS: ${checks} fixed WebKit script checks`);
})().catch(e=>{console.error('FAIL:', e.message);process.exit(1)});

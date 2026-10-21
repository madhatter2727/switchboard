import json,sys,time,urllib.request,os
m=sys.argv[1]
TOOLS=[{"type":"function","function":{"name":"list_folder","description":"List the files and folders directly inside one folder.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Folder path"}},"required":["path"]}}},
{"type":"function","function":{"name":"read_file_text","description":"Read the text of a plain text file.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]
msgs=[{"role":"system","content":"You are an assistant on this Mac. Use tools for files and folders; do not invent contents."},
{"role":"user","content":"What files are in the folder ~/Projects/model-picker/test-sandbox ?"}]
def call(msgs):
  b={"model":m,"messages":msgs,"tools":TOOLS,"tool_choice":"auto","stream":False,"temperature":0.3,"reasoning_effort":"none","chat_template_kwargs":{"enable_thinking":False},"max_tokens":1200}
  r=urllib.request.Request("http://127.0.0.1:7777/v1/chat/completions",data=json.dumps(b).encode(),headers={"Content-Type":"application/json"})
  return json.load(urllib.request.urlopen(r,timeout=400))["choices"][0]["message"]
t=time.time();out={"model":m}
try:
  msg=call(msgs);calls=msg.get("tool_calls") or []
  out["native_tool_calls"]=[(c["function"]["name"],c["function"]["arguments"]) for c in calls]
  out["content"]=(msg.get("content") or "")[:300]
  if not calls:
    try:
      o=json.loads((msg.get("content") or "").strip().strip("`").removeprefix("json").strip());o=o[0] if isinstance(o,list) else o;f=o.get("function",o)
      if f.get("name") in("list_folder","read_file_text"):out["text_tool_call"]=f.get("name")
    except Exception:pass
  ok=bool(calls) and calls[0]["function"]["name"]=="list_folder"
  if ok:
    listing="\n".join(sorted(os.listdir(os.path.expanduser("~/Projects/model-picker/test-sandbox"))))
    msgs+= [{"role":"assistant","content":msg.get("content"),"tool_calls":calls},{"role":"tool","tool_call_id":calls[0].get("id","t0"),"name":"list_folder","content":listing}]
    msg2=call(msgs);out["final"]=(msg2.get("content") or "")[:300];out["final_tool_calls"]=bool(msg2.get("tool_calls"))
  out["pass_native"]=ok
except Exception as e: out["error"]=str(e)[:300]
out["sec"]=round(time.time()-t,1)
print(json.dumps(out))
open("results.jsonl","a").write(json.dumps(out)+"\n")

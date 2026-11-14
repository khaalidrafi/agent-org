#!/usr/bin/env python3
"""ELisp internship battery — Ant Ling models on OpenRouter, static-scored."""
import urllib.request, json, re, sys

KEY = open("/home/z/my-project/vault-clone/secrets/OPENROUTER_API_KEY").read().strip()
OUT = "/tmp/intern"
import os; os.makedirs(OUT, exist_ok=True)

def ask(model, prompt, maxtok=3000):
    body = json.dumps({"model": model,
                       "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": maxtok, "temperature": 0}).encode()
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
        data=body, headers={"Authorization": "Bearer " + KEY,
                            "Content-Type": "application/json",
                            "User-Agent": "zai-agent-intern"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
        ch = d["choices"][0]["message"]
        cost = d.get("usage", {}).get("cost", 0)
        return (ch.get("content") or ""), (ch.get("reasoning") or ""), cost
    except Exception as e:
        return "", "ERR:%s" % e, 0

TASKS = {
"T1-write": """Write ONE Emacs Lisp defun: (agent-intern--todo-parse LINE) -> cons (STATE . TITLE).
LINE examples: "** TODO fix the parser", "** DONE ship it", "** WAITING review", "plain text", "** TODO".
Rules: if LINE starts with the two-char prefix "** " followed by an ALL-CAPS word ([A-Z]+) and then either end-of-string or a space, return (KEYWORD . rest) where rest is everything after the keyword and one space (empty string if end). Otherwise return (nil . LINE). Include a docstring. Output ONLY one code block.""",

"T2-fix": """This Emacs Lisp function is buggy. It must return the FIRST line of TEXT that starts with the PREFIX, or nil. Fix it. Output ONLY one code block with the corrected function.
(defun agent-intern--first-prefixed (prefix text)
  "Return the first line of TEXT starting with PREFIX, or nil."
  (let ((lines (split-string text "\\n")))
    (catch 'found
      (dolist (line lines)
        (when (string= prefix line)
          (throw 'found line))))))""",

"T3-conventions": """Refactor to our conventions: docstring must be a complete first sentence, use `setq-local` not `setq` for buffer-locals, prefer `seq-filter` over cl-loop. Output ONLY one code block.
(defun agent-intern--collect (buf)
  "collect todo lines"
  (with-current-buffer buf
    (setq my-collected nil)
    (cl-loop for l in (split-string (buffer-string) "\\n")
             when (string-prefix-p "** " l) collect l into out
             finally return out)))""",

"T4-api": """Answer with ONE letter per line, nothing else. (1) Which returns a NEW list? a) mapc b) mapcar. (2) Buffer-local binding that survives with-current-buffer? a) setq b) setq-local c) let. (3) Does `string-prefix-p "a" "ab"` return t? a) yes b) no. (4) `buffer-string` returns? a) whole buffer text b) current line c) region.""",
}

def grade(t, out_txt):
    s = 0; notes = []
    code = out_txt
    m = re.search(r"```(?:elisp|emacs-lisp|el)?\s*\n(.*?)```", out_txt, re.S)
    if m: code = m.group(1)
    if t == "T1-write":
        checks = [("defun", "defun agent-intern--todo-parse" in code),
                  ("docstring", '"' in code and ('"Return' in code or '"If' in code or 'docstring' in code.lower() or '\n  "' in code)),
                  ("prefix ** ", ("**" in code and ("string-prefix-p" in code or "string-match" in code))),
                  ("caps word", re.search(r'[A-Z]+', code) is not None or "upper-case-p" in code),
                  ("cons return", ("cons" in code) or re.search(r'\(\s*kw', code) or "(nil" in code)]
        s = sum(1 for _, ok in checks if ok); notes = ["%s=%s" % (n, ok) for n, ok in checks]
    elif t == "T2-fix":
        checks = [("not string= whole line", "(string= prefix line)" not in code),
                  ("prefix-p used", "string-prefix-p" in code),
                  ("dolist/catch kept", "dolist" in code),
                  ("docstring kept", '"Return the first line' in code)]
        s = sum(1 for _, ok in checks if ok); notes = ["%s=%s" % (n, ok) for n, ok in checks]
    elif t == "T3-conventions":
        checks = [("docstring complete sentence", re.search(r'"[A-Z][^"]*\."', code) is not None),
                  ("setq-local", "setq-local" in code),
                  ("no cl-loop", "cl-loop" not in code),
                  ("seq-filter", "seq-filter" in code)]
        s = sum(1 for _, ok in checks if ok); notes = ["%s=%s" % (n, ok) for n, ok in checks]
    elif t == "T4-api":
        letters = re.findall(r'[abcd]', out_txt.lower())
        want = list("bbaa")  # 1:mapcar=b 2:setq-local=b 3:yes=a 4:whole=a
        s = sum(1 for g, w in zip(letters, want) if g == w)
        notes = ["answers=%s" % "".join(letters[:4])]
    return s, notes

MODELS = ["inclusionai/ling-3.1-flash", "inclusionai/ling-3.0-flash"]
scorecards = {}
for model in MODELS:
    sc = {}
    for t, prompt in TASKS.items():
        content, reasoning, cost = ask(model, prompt)
        score, notes = grade(t, content if content.strip() else reasoning)
        sc[t] = (score, notes, cost, (content or reasoning)[:400])
        print("%s | %s | %d | %s" % (model.split("/")[1], t, score, ",".join(notes)))
    scorecards[model] = sc
    print()

json.dump(scorecards, open(OUT + "/scorecards.json", "w"), indent=1)
print("saved", OUT + "/scorecards.json")
